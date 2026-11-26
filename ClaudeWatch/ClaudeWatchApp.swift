import AppKit
import SwiftUI

@main
struct ClaudeWatchApp: App {
    @State private var store: UsageStore

    init() {
        LegacyMigration.run()  // before the store reads settings and the scanner reads its cache
        // An update may bring a newer status line script or plugin. Not from tests: the test host is the app.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            StatusLineSetup().updateScriptIfSetUp()
            Task.detached(priority: .utility) { PluginSetup().updateIfSetUp() } // runs `claude`
        }
        _store = State(initialValue: UsageStore())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The 5-hour and weekly plan usage and/or the selected period's AWS cost, as chosen in Settings,
/// e.g. "5h 85% · 7d 12% · $3.20". The labels match ClaudeWatch's status line.
///
/// Drawn as one fixed-width image: the menu content hangs under this item, so if the item changed
/// width with every new number (or period), the whole menu would jump sideways.
struct MenuBarLabel: View {
    let store: UsageStore

    var body: some View {
        let parts = self.parts
        Image(nsImage: MenuBarImage.render(parts))
            .accessibilityLabel(parts.isEmpty ? "ClaudeWatch" : parts.map { $0.spoken ?? $0.text }.filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private var parts: [MenuBarImage.Part] {
        typealias Part = MenuBarImage.Part
        var result: [Part] = []
        let showPlan = store.menuBarDisplay == .planAndCloud || store.menuBarDisplay == .plan
        let showCloud = store.menuBarDisplay == .planAndCloud || store.menuBarDisplay == .cloud
        if showPlan, let usage = store.planUsage {
            for (label, name, value) in [("5h", "5-hour", usage.fiveHour()), ("7d", "weekly", usage.weekly())] {
                guard let value else { continue }
                let percent = "\(Int(value.rounded()))%"
                // The label and its number in slots of their own, so the padding sits between them.
                result.append(Part(text: label, widestText: [], alignRight: false, spoken: ""))
                result.append(Part(
                    text: percent, widestText: ["100%"], alignRight: true, spoken: "\(name) \(percent)", separator: " "
                ))
            }
        }
        if showCloud, store.hasScanned {
            let costs = store.cloudCostByPeriod
            result.append(Part(
                text: Format.money(costs[store.period] ?? 0),
                widestText: Period.allCases.map { Format.money(costs[$0] ?? 0) },
                alignRight: false
            ))
        }
        return result
    }
}

@MainActor
enum MenuBarImage {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    nonisolated static let separator = " · "

    struct Part {
        var text: String
        /// Texts this part may show; its slot is always as wide as the widest of them.
        var widestText: [String]
        var alignRight: Bool
        /// For VoiceOver, if the text is too terse; empty to leave the part out.
        var spoken: String? = nil
        /// Drawn before the part, unless it comes first.
        var separator = MenuBarImage.separator
    }

    /// The chart icon followed by the parts, each in a slot as wide as its widest text.
    static func render(_ parts: [Part]) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        func width(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: attributes).width) }

        let symbol = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: NSFont.systemFontSize, weight: .regular))
        let iconSize = symbol?.size ?? CGSize(width: 16, height: 16)
        let slots = parts.map { part in max(width(part.text), part.widestText.map(width).max() ?? 0) }
        let gap: CGFloat = parts.isEmpty ? 0 : 4
        let textWidth = slots.reduce(0, +) + parts.dropFirst().map { width($0.separator) }.reduce(0, +)
        let height = max(iconSize.height, ceil(font.ascender - font.descender))
        let size = CGSize(width: ceil(iconSize.width + gap + textWidth), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            symbol?.draw(in: CGRect(x: 0, y: (height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
            var x = iconSize.width + gap
            let baselineY = (height - (font.ascender - font.descender)) / 2 - font.descender
            let y = baselineY + font.descender
            for (index, (part, slot)) in zip(parts, slots).enumerated() {
                if index > 0 {
                    (part.separator as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
                    x += width(part.separator)
                }
                let offset = part.alignRight ? slot - width(part.text) : 0
                (part.text as NSString).draw(at: CGPoint(x: x + offset, y: y), withAttributes: attributes)
                x += slot
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
