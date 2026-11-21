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
                Text("A session counts toward a pin if its id matches, or if its name (`claude -n <name>`) equals the label.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach($store.pinned) { $pin in
                    HStack(spacing: 6) {
                        TextField("Label", text: $pin.label).frame(width: 110)
                        TextField("Session id", text: $pin.sessionID).font(.caption.monospaced())
                        Button {
                            store.pinned.removeAll { $0.id == pin.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
                HStack {
                    Button("Add") {
                        store.pinned.append(PinnedSession(label: "", sessionID: UUID().uuidString.lowercased()))
                    }
                    Button("Import from ~/.zshrc") { store.importFromShellConfig() }
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

            if store.dailyBudget > 0 && !store.notificationsAllowed {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "bell.slash").foregroundStyle(.orange)
                    Text("Notifications are off for TokenTally.").font(.callout)
                    Button("Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Toggle("Show Pro plan limits", isOn: $store.showPlanLimits)
                Text("Uses the plan login Claude Code keeps in your keychain. macOS asks once whether TokenTally may read it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            .toggleStyle(.checkbox)

            Toggle(
                "Launch at login",
                isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) })
            )
            .toggleStyle(.checkbox)
        }
    }
}
