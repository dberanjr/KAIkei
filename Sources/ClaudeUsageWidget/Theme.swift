import AppKit
import SwiftUI
import UsageCore

/// Chart colors are the validated categorical slots 1-3 (light/dark stepped separately). Everything else
/// uses system ink so the widget follows the user's appearance.
enum Theme {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static func color(_ family: ModelFamily) -> Color {
        switch family {
        case .opus: return dynamic(light: 0x2a78d6, dark: 0x3987e5)
        case .sonnet: return dynamic(light: 0xeb6834, dark: 0xd95926)
        case .haiku: return dynamic(light: 0x1baf7a, dark: 0x199e70)
        case .other: return dynamic(light: 0x8a8a85, dark: 0x8a8a85)
        }
    }

    /// Claude's brand orange (#D97757). Used only as a faint wash in the header, never for data: the chart's
    /// orange already means "Sonnet", so this stays subdued and out of the charts.
    static let claudeOrange = Color(nsColor: NSColor(hex: 0xd97757))
    static let accent = dynamic(light: 0x2a78d6, dark: 0x3987e5)
    // Sequential blue ramp for the ordinal "where the money goes" bar (lightest step still clears 2:1).
    static let ramp: [Color] = [
        dynamic(light: 0x86b6ef, dark: 0x6da7ec), dynamic(light: 0x5598e7, dark: 0x3987e5),
        dynamic(light: 0x256abf, dark: 0x2a78d6), dynamic(light: 0x104281, dark: 0x1c5cab),
    ]
    // One hue family per chart type, so a series keeps its color when it is overlaid on another chart. Blue is the
    // context window (`ramp` above); these are the other three. The four hues were run through the palette validator
    // (separation under color-blind simulation, lightness band, contrast) in both appearances.
    static let seriesOutput = dynamic(light: 0x6250d6, dark: 0x9085e9)
    static let seriesCostPerCall = dynamic(light: 0xc33f72, dark: 0xc94f7c)
    static let seriesCumulative = dynamic(light: 0xc98500, dark: 0xc98500)
    /// Dollars by what they were billed as (cache read, cache write, output, input): a light-to-dark magenta ramp, the
    /// cost chart's own family, so it never reads as the blue token ramp.
    static let billedRamp: [Color] = [
        dynamic(light: 0xe79fbc, dark: 0xe0a0bb), dynamic(light: 0xdd6b93, dark: 0xd9779c),
        dynamic(light: 0xc33f72, dark: 0xc94f7c), dynamic(light: 0x8f2150, dark: 0x9a3560),
    ]
    static let caution = Color(nsColor: .systemOrange)
    static let critical = Color(nsColor: .systemRed)
    static let good = Color(nsColor: .systemGreen)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

enum Fmt {
    static func money(_ v: Double) -> String {
        if v == 0 { return "$0.00" }
        if v < 0.01 { return "<$0.01" }
        return v.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<10_000: return String(format: "%.1fK", Double(n) / 1_000)
        case ..<1_000_000: return String(format: "%.0fK", Double(n) / 1_000)
        case ..<10_000_000: return String(format: "%.2fM", Double(n) / 1_000_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    static func moneyWhole(_ v: Double) -> String { v.formatted(.currency(code: "USD").precision(.fractionLength(0))) }

    /// Axis label: whole dollars when the tick is whole, cents otherwise, so a $0.50 scale never reads "$1, $1, $0".
    static func axisMoney(_ v: Double) -> String { v == v.rounded() ? String(format: "$%.0f", v) : String(format: "$%.2f", v) }

    /// "1 response", "2 responses": a count never reads as "1 responses".
    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v) }

    /// "Oct 25, 2:10 – 3:45 PM" on one day, with both dates when it spans days. Seconds appear for windows under ten minutes.
    static func range(_ a: Date, _ b: Date) -> String {
        let short = b.timeIntervalSince(a) < 600
        let time: Date.FormatStyle = short ? .dateTime.hour().minute().second() : .dateTime.hour().minute()
        if Calendar.current.isDate(a, inSameDayAs: b) {
            return "\(a.formatted(.dateTime.month(.abbreviated).day())), \(a.formatted(time)) – \(b.formatted(time))"
        }
        let both = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        return "\(a.formatted(both)) – \(b.formatted(both))"
    }

    /// How long a stretch is: "45s", "12m", "3h 15m".
    static func spanLength(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" + (s < 600 && s % 60 != 0 ? " \(s % 60)s" : "") }
        return duration(s)
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
