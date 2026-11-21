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
            .help("Added to Anthropic list prices for Bedrock requests. AWS charges more for geographic (eu., us.) inference profiles on some models; check your AWS bill.")

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

            if (store.dailyBudget > 0 || store.planAlertPercent > 0) && !store.notificationsAllowed {
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
