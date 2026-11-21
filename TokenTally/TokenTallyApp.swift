import SwiftUI

@main
struct TokenTallyApp: App {
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Today's AWS cost (or AWS + plan value), plus the 5-hour plan window when that's turned on.
struct MenuBarLabel: View {
    let store: UsageStore

    var body: some View {
        Image(systemName: "chart.bar.xaxis")
        if let text {
            Text(text).monospacedDigit()
        }
    }

    private var text: String? {
        var parts: [String] = []
        if store.hasScanned {
            switch store.menuBarDisplay {
            case .cloudToday: parts.append(Format.money(store.today.cloudCost))
            case .allToday: parts.append(Format.money(store.today.cost))
            case .iconOnly: break
            }
        }
        if store.showPlanLimits, let session = store.planLimits.first(where: { $0.id == "five_hour" }) {
            parts.append("\(Int(session.utilization.rounded()))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
