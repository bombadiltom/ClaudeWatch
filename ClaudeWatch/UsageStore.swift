import AppKit
import Observation
import ServiceManagement
@preconcurrency import UserNotifications

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case planAndCloud, plan
    case cloud = "cloudToday"
    case iconOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .planAndCloud: "5-hour plan usage + AWS cost"
        case .plan: "5-hour plan usage"
        case .cloud: "AWS cost"
        case .iconOnly: "Icon only"
        }
    }
}

@MainActor
@Observable
final class UsageStore {
    static let scanInterval: TimeInterval = 30
    /// Plan limits change with every request anywhere on the account, and their sources are two
    /// small files, so they're re-read more often than the transcripts.
    static let planInterval: TimeInterval = 5

    private(set) var report = UsageReport.empty
    /// AWS cost of each period, for the menu bar (which shows the selected period).
    private(set) var cloudCostByPeriod: [Period: Double] = [:]
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var lastUpdated: Date?
    /// Plan utilization from Claude Desktop or Claude Code's own readings, brought up to date with
    /// the Claude Code usage since (see `PlanEstimator`); nil if neither has recorded any.
    private(set) var planUsage: PlanUsage?
    /// Desktop's reading as saved.
    private var desktopPlanUsage: PlanUsage?
    /// Limits Claude Code saw, from the plugin or the status line (see `LiveLimitsReader`).
    private var liveReadings: [LimitReading] = []
    /// When the plugin or the status line last saved the limits, for Settings.
    var liveLimitsUpdated: Date? { liveReadings.map(\.date).max() }
    /// The last week's plan requests, kept between scans for `refreshPlan`.
    private var planRequestCache: [PlanEstimator.Usage] = []
    private var isReadingPlan = false
    private(set) var notificationsAllowed = true
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    var period: Period {
        didSet { defaults.set(period.rawValue, forKey: Keys.period); rebuild() }
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

    /// Notify when the 5-hour plan usage reaches this percentage. 0 turns it off.
    var planAlertPercent: Double {
        didSet {
            defaults.set(planAlertPercent, forKey: Keys.planAlert)
            if planAlertPercent > 0 { requestNotificationPermission() }
            evaluatePlanAlert()
        }
    }

    /// Notify when the weekly plan usage reaches this percentage. 0 turns it off.
    var weeklyAlertPercent: Double {
        didSet {
            defaults.set(weeklyAlertPercent, forKey: Keys.weeklyAlert)
            if weeklyAlertPercent > 0 { requestNotificationPermission() }
            evaluatePlanAlert()
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
        period = Period(rawValue: defaults.string(forKey: Keys.period) ?? "") ?? .today
        cloudSurchargePercent = defaults.double(forKey: Keys.surcharge)
        menuBarDisplay = MenuBarDisplay(rawValue: defaults.string(forKey: Keys.display) ?? "") ?? .planAndCloud
        dailyBudget = defaults.double(forKey: Keys.budget)
        planAlertPercent = defaults.object(forKey: Keys.planAlert) as? Double ?? 80
        weeklyAlertPercent = defaults.object(forKey: Keys.weeklyAlert) as? Double ?? 80

        UNUserNotificationCenter.current().delegate = notificationDelegate
        Task { await updateNotificationStatus() }
        if planAlertPercent > 0 || weeklyAlertPercent > 0 || dailyBudget > 0 { requestNotificationPermission() }

        refresh()
        timers.append(Timer.scheduledTimer(withTimeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: Self.planInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPlan() }
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
            let (live, titles, factors, plan, readings) = await Task.detached(priority: .utility) {
                (SessionDirectory.liveSessions(), SessionDirectory.desktopTitles(),
                 SideRequests.factors(entries: result.entries, snapshots: result.snapshots),
                 PlanUsageReader.read(), LiveLimitsReader.read(prune: !Self.isTesting))
            }.value
            self.scan = result
            self.desktopPlanUsage = plan
            self.liveReadings = readings
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
        cloudCostByPeriod = UsageReport.cloudCosts(entries: scan.entries, cloudSurcharge: surcharge, factors: factors)
        planRequestCache = planRequests()
        updatePlanUsage()
        evaluateBudget()
    }

    /// Re-reads only the plan limits: Desktop's samples and Claude Code's readings.
    func refreshPlan() {
        guard hasScanned, !isScanning, !isReadingPlan else { return }
        isReadingPlan = true
        Task {
            let (plan, readings) = await Task.detached(priority: .utility) {
                (PlanUsageReader.read(), LiveLimitsReader.read(prune: false))
            }.value
            self.isReadingPlan = false
            self.desktopPlanUsage = plan
            self.liveReadings = readings
            // Even without new readings, a window may just have reset.
            self.updatePlanUsage()
        }
    }

    private func updatePlanUsage() {
        let estimated = PlanEstimator.estimate(
            desktopPlanUsage, plan: planRequestCache, readings: scan.limitReadings + liveReadings
        )
        if planUsage != estimated { planUsage = estimated }
        evaluatePlanAlert()
    }

    private nonisolated static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// The last week's plan (non-cloud) requests with their API value, for `PlanEstimator`.
    private func planRequests(now: Date = .now) -> [PlanEstimator.Usage] {
        let since = now.addingTimeInterval(-7 * 86_400)
        return scan.entries.compactMap { entry in
            guard !entry.backend.isCloudBilled, entry.timestamp > since else { return nil }
            let value = (Pricing.cost(of: entry) ?? 0) * (factors[entry.messageID] ?? 1)
            return PlanEstimator.Usage(date: entry.timestamp, value: value)
        }
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
        let today = cloudCostByPeriod[.today] ?? 0
        guard dailyBudget > 0, hasScanned, today >= dailyBudget else { return }
        let day = Self.dayKey(.now)
        guard defaults.string(forKey: Keys.budgetAlertDay) != day else { return }
        defaults.set(day, forKey: Keys.budgetAlertDay)

        let content = UNMutableNotificationContent()
        content.title = "AWS spend today: \(Format.money(today))"
        content.body = "Your Claude Code sessions on Bedrock passed your daily budget of \(Format.money(dailyBudget))."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "budget-\(day)", content: content, trigger: nil)
        )
    }

    // MARK: - Plan alerts

    /// Notifies once when the 5-hour or weekly usage reaches its threshold, and again only after it
    /// has dropped below (a new window).
    private func evaluatePlanAlert() {
        guard let usage = planUsage else { return }
        alert(
            usage: usage.fiveHour(), threshold: planAlertPercent, firedKey: Keys.planAlertFired,
            name: "5-hour", resetsAt: usage.limit(PlanUsageReader.fiveHour)?.resetsAt
        )
        alert(
            usage: usage.limit(PlanUsageReader.weekly)?.utilization, threshold: weeklyAlertPercent,
            firedKey: Keys.weeklyAlertFired, name: "weekly", resetsAt: nil
        )
    }

    private func alert(usage: Double?, threshold: Double, firedKey: String, name: String, resetsAt: Date?) {
        guard threshold > 0, let usage else { return }
        let fired = defaults.bool(forKey: firedKey)
        if usage < threshold {
            if fired { defaults.set(false, forKey: firedKey) }
            return
        }
        guard !fired else { return }
        defaults.set(true, forKey: firedKey)

        let content = UNMutableNotificationContent()
        content.title = "\(name.prefix(1).uppercased() + name.dropFirst()) plan usage at \(Int(usage.rounded()))%"
        if let resetsAt {
            content.body = "The window resets at about \(resetsAt.formatted(date: .omitted, time: .shortened))."
        } else {
            content.body = "You've passed \(Int(threshold))% of your plan's \(name) limit."
        }
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "\(firedKey)-\(Int(Date.now.timeIntervalSince1970))", content: content, trigger: nil)
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
        static let period = "period"
        static let planAlert = "planAlertPercent"
        static let planAlertFired = "planAlertFired"
        static let weeklyAlert = "weeklyAlertPercent"
        static let weeklyAlertFired = "weeklyAlertFired"
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
