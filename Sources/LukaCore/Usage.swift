import Foundation

/// Audio sent to Soniox, split by what it is billed as. Each open stream bills for the audio it hears,
/// so two streams on the same second (three-way, Me / Them) count twice, as Soniox counts them.
public struct UsageTotals: Codable, Sendable, Equatable {
    public var transcribeMs: Int = 0
    public var translateMs: Int = 0

    public init(transcribeMs: Int = 0, translateMs: Int = 0) {
        self.transcribeMs = transcribeMs
        self.translateMs = translateMs
    }

    /// Soniox's published real-time rates, in USD per hour of audio (soniox.com/pricing, Nov 2026).
    /// Real bills are per token and can differ a little; this is an estimate.
    public static let transcribeRate = 0.12
    public static let translateRate = 0.18

    public var totalMs: Int { transcribeMs + translateMs }
    public var minutes: Double { Double(totalMs) / 60_000 }

    public var estimatedCost: Double {
        Double(transcribeMs) / 3_600_000 * Self.transcribeRate + Double(translateMs) / 3_600_000 * Self.translateRate
    }

    public mutating func add(ms: Int, translated: Bool) {
        if translated { translateMs += ms } else { transcribeMs += ms }
    }

    public static func + (a: UsageTotals, b: UsageTotals) -> UsageTotals {
        UsageTotals(transcribeMs: a.transcribeMs + b.transcribeMs, translateMs: a.translateMs + b.translateMs)
    }

    /// "12 min · ≈ $0.04", or "3.2 h · ≈ $0.58" past two hours.
    public var summary: String {
        let time = minutes >= 120 ? String(format: "%.1f h", minutes / 60) : String(format: "%.0f min", minutes.rounded(.up))
        return "\(time) · ≈ $" + String(format: "%.2f", estimatedCost)
    }

    /// The key a month's totals are stored under, such as "2026-11".
    public static func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
