import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var store: UsageStore
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Pinned sessions").font(.subheadline.weight(.semibold))
                Text("Right-click a session in the menu to pin it. A session counts toward a pin if its id matches, or if its name (`claude -n <name>`) equals the label.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Bindings by id, not by index: removing a pin must not leave a field reading a stale index.
                ForEach(store.pinned) { pin in
                    HStack(spacing: 6) {
                        TextField("Label", text: binding(pin.id, \.label)).frame(width: 110)
                        TextField("Session id", text: binding(pin.id, \.sessionID)).font(.caption.monospaced())
                        Button {
                            store.unpin(pin.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
                Button("Add") {
                    store.pinned.append(PinnedSession(label: "", sessionID: ""))
                }
                .controlSize(.small)
            }

            Divider()

            Picker("Menu bar shows", selection: $store.menuBarDisplay) {
                ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
            }

            HStack {
                Text("Bedrock surcharge")
                Spacer()
                TextField("0", value: $store.cloudSurchargePercent, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 50)
                    .multilineTextAlignment(.trailing)
                Text("%")
            }
            .help("Added to Anthropic list prices for Bedrock requests. Geographic (eu., us., jp. …) and in-region inference profiles cost 10% more than global ones for current Claude models, so set 10 if you use them.")

            HStack {
                Text("Notify when today's AWS cost passes")
                Spacer()
                TextField("off", value: $store.dailyBudget, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("$")
            }
            .help("0 turns the alert off. You get one notification per day.")

            HStack {
                Text("Notify when 5-hour plan usage reaches")
                Spacer()
                TextField("off", value: $store.planAlertPercent, format: .number.precision(.fractionLength(0)))
                    .frame(width: 50)
                    .multilineTextAlignment(.trailing)
                Text("%")
            }
            .help("0 turns the alert off. You get one notification per 5-hour window.")

            HStack {
                Text("Notify when weekly plan usage reaches")
                Spacer()
                TextField("off", value: $store.weeklyAlertPercent, format: .number.precision(.fractionLength(0)))
                    .frame(width: 50)
                    .multilineTextAlignment(.trailing)
                Text("%")
            }
            .help("0 turns the alert off. You get one notification per week.")

            if (store.dailyBudget > 0 || store.planAlertPercent > 0 || store.weeklyAlertPercent > 0) && !store.notificationsAllowed {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "bell.slash").foregroundStyle(.orange)
                    Text("Notifications are off for ClaudeWatch.").font(.callout)
                    Button("Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
            }

            Divider()

            LiveLimitsSetupView(lastReading: store.liveLimitsUpdated)

            Divider()

            Toggle(
                "Launch at login",
                isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) })
            )
            .toggleStyle(.checkbox)

            Divider()

            HStack {
                Text(Self.version).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Link("GitHub", destination: URL(string: "https://github.com/bombadiltom/ClaudeWatch")!)
                    .font(.caption)
            }
        }
    }

    /// "ClaudeWatch 1.4 (52)"
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "ClaudeWatch \(short) (\(build))"
    }

    private func binding(_ id: PinnedSession.ID, _ field: WritableKeyPath<PinnedSession, String>) -> Binding<String> {
        Binding(
            get: { store.pinned.first { $0.id == id }?[keyPath: field] ?? "" },
            set: { value in
                guard let index = store.pinned.firstIndex(where: { $0.id == id }) else { return }
                store.pinned[index][keyPath: field] = value
            }
        )
    }
}

/// Sets up ClaudeWatch's status line in Claude Code, which gives the exact plan limits (see
/// `StatusLineSetup`). Only ever on a click: it edits Claude Code's settings, not ClaudeWatch's.
struct LiveLimitsSetupView: View {
    let lastReading: Date?
    var setup = StatusLineSetup()
    @State private var state: StatusLineSetup.State?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Live plan limits").font(.subheadline.weight(.semibold))
                Spacer()
                switch state {
                case .setUp:
                    Button("Remove") { run(setup.remove) }.controlSize(.small)
                case .notSetUp, .otherStatusLine:
                    Button("Set Up") { run(setup.install) }.controlSize(.small)
                case .unreadable, nil:
                    EmptyView()
                }
            }
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { state = setup.state() }
    }

    private var explanation: String {
        switch state {
        case .setUp(let wrapping):
            let reading = lastReading.map { "Last reading \(Self.time($0))." }
                ?? "The first reading comes with the next response in a Claude Code terminal session."
            let yours = wrapping.map { " Your own status line (“\(Self.short($0))”) keeps running." } ?? ""
            return "Claude Code's status line hands ClaudeWatch your exact plan limits, Desktop and Cowork included. \(reading)\(yours)"
        case .otherStatusLine(let command):
            return "Claude Code can hand ClaudeWatch your exact plan limits, Desktop and Cowork included, through its status line. Set Up adds ClaudeWatch's script to ~/.claude/settings.json and keeps your status line (“\(Self.short(command))”) running."
        case .unreadable:
            return "ClaudeWatch can't read ~/.claude/settings.json (or its status line has no command), so it can't set up live plan limits. Its README shows how to set them up by hand."
        case .notSetUp, nil:
            return "Claude Code can hand ClaudeWatch your exact plan limits, Desktop and Cowork included, through its status line. Set Up copies ClaudeWatch's script to ~/.claude/ and adds it to ~/.claude/settings.json. It works in terminal sessions on your plan."
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        state = setup.state()
    }

    private static func short(_ command: String) -> String {
        command.count > 48 ? command.prefix(47) + "…" : command
    }

    /// "14:51" today, "Mon 14:51" on another day.
    private static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
