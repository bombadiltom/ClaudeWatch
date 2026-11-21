import AppKit
import Observation
import ServiceManagement
@preconcurrency import UserNotifications

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case planAndCloud, plan, cloudToday, iconOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .planAndCloud: "5-hour plan usage + AWS cost today"
        case .plan: "5-hour plan usage"
        case .cloudToday: "AWS cost today"
        case .iconOnly: "Icon only"
        }
    }
}

@MainActor
@Observable
final class UsageStore {
    static let scanInterval: TimeInterval = 30

    private(set) var report = UsageReport.empty
    private(set) var today = Totals()
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var lastUpdated: Date?
    /// Plan utilization from Claude Desktop; nil if Desktop hasn't recorded any.
    private(set) var planUsage: PlanUsage?
    private(set) var notificationsAllowed = true
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    var period: Period = .today {
        didSet { rebuild() }
    }

    var pinned: [PinnedSession] {
        didSet { save(pinned, forKey: Keys.pinned); rebuild() }
    }

    /// Extra charge on Bedrock/Vertex requests over Anthropic list price, in percent.
    var cloudSurchargePercent: Double {
        didSet { defaults.set(cloudSurchargePercent, forKey: Keys.surcharge); rebuild() }
    }

    var menuBarDisplay: MenuBarDisplay {
        didSet { defaults.set(menuBarDisplay.rawValue, forKey: Keys.display) }
    }

    /// Notify once a day when today's AWS cost passes this many dollars. 0 turns it off.
    var dailyBudget: Double {
        didSet {
            defaults.set(dailyBudget, forKey: Keys.budget)
            if dailyBudget > 0 { requestNotificationPermission() }
            evaluateBudget()
        }
    }

    private let scanner = TranscriptScanner()
    private var scan = ScanResult(entries: [], titles: [:])
    private var factors: [String: Double] = [:]
    private var live: [LiveSession] = []
    private var desktopTitles: [String: String] = [:]
    private var timers: [Timer] = []
    private let notificationDelegate = NotificationDelegate()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.pinned),
           let stored = try? JSONDecoder().decode([PinnedSession].self, from: data) {
            pinned = stored
        } else {
            pinned = []
        }
        cloudSurchargePercent = defaults.double(forKey: Keys.surcharge)
        menuBarDisplay = MenuBarDisplay(rawValue: defaults.string(forKey: Keys.display) ?? "") ?? .planAndCloud
        dailyBudget = defaults.double(forKey: Keys.budget)

        UNUserNotificationCenter.current().delegate = notificationDelegate
        Task { await updateNotificationStatus() }

        refresh()
        timers.append(Timer.scheduledTimer(withTimeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Refreshing

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let result = await scanner.scan()
            let (live, titles, factors, plan) = await Task.detached(priority: .utility) {
                (SessionDirectory.liveSessions(), SessionDirectory.desktopTitles(),
                 SideRequests.factors(entries: result.entries, snapshots: result.snapshots),
                 PlanUsageReader.read())
            }.value
            self.scan = result
            if self.planUsage != plan { self.planUsage = plan }
            self.factors = factors
            self.live = live
            self.desktopTitles = titles
            self.isScanning = false
            self.hasScanned = true
            self.lastUpdated = .now
            self.rebuild()
        }
    }

    private func rebuild() {
        let titles = scan.titles.merging(desktopTitles) { _, desktop in desktop }
        let surcharge = cloudSurchargePercent / 100
        report = UsageReport.build(
            entries: scan.entries, period: period, pinned: pinned, titles: titles, live: live,
            cloudSurcharge: surcharge, factors: factors
        )
        if period == .today {
            today = report.overall
        } else {
            today = UsageReport.build(
                entries: scan.entries, period: .today, pinned: [], titles: [:], live: [],
                cloudSurcharge: surcharge, factors: factors
            ).overall
        }
        evaluateBudget()
    }

    // MARK: - Settings

    func pin(sessionID: String, label: String) {
        guard !pinned.contains(where: { $0.sessionID.caseInsensitiveCompare(sessionID) == .orderedSame }) else { return }
        pinned.append(PinnedSession(label: label, sessionID: sessionID))
    }

    func unpin(_ id: PinnedSession.ID) {
        pinned.removeAll { $0.id == id }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("ClaudeWatch: launch-at-login change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Budget alert

    private func evaluateBudget() {
        guard dailyBudget > 0, hasScanned, today.cloudCost >= dailyBudget else { return }
        let day = Self.dayKey(.now)
        guard defaults.string(forKey: Keys.budgetAlertDay) != day else { return }
        defaults.set(day, forKey: Keys.budgetAlertDay)

        let content = UNMutableNotificationContent()
        content.title = "AWS spend today: \(Format.money(today.cloudCost))"
        content.body = "Your Claude Code sessions on Bedrock passed your daily budget of \(Format.money(dailyBudget))."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "budget-\(day)", content: content, trigger: nil)
        )
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private func requestNotificationPermission() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await updateNotificationStatus()
        }
    }

    private func updateNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .notDetermined
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private enum Keys {
        static let pinned = "pinnedSessions"
        static let surcharge = "cloudSurchargePercent"
        static let display = "menuBarDisplay"
        static let budget = "dailyBudget"
        static let budgetAlertDay = "budgetAlertDay"
    }
}

/// Shows banners even if the app happens to be active.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

enum Format {
    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value >= 100 ? 0 : 2)))
    }

    static func tokens(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }
}
