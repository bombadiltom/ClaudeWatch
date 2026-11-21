import SwiftUI

@main
struct ClaudeWatchApp: App {
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

/// The 5-hour plan usage and/or today's AWS cost, as chosen in Settings.
struct MenuBarLabel: View {
    let store: UsageStore

    var body: some View {
        Image(systemName: "chart.bar.xaxis")
        if let text {
            Text(text).monospacedDigit()
        }
    }

    private var text: String? {
        let plan = store.planUsage?.fiveHour().map { "\(Int($0.rounded()))%" }
        let cloud = store.hasScanned ? Format.money(store.today.cloudCost) : nil
        let parts: [String?] = switch store.menuBarDisplay {
        case .planAndCloud: [plan, cloud]
        case .plan: [plan]
        case .cloudToday: [cloud]
        case .iconOnly: []
        }
        let shown = parts.compactMap { $0 }
        return shown.isEmpty ? nil : shown.joined(separator: " · ")
    }
}
