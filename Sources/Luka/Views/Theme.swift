import AppKit
import SwiftUI

/// Luka Plus's look: an electric blue that runs into cyan, hairline edges that catch the light
/// at the top, and quiet cards. Colors adapt to light and dark appearance.
enum LukaTheme {
    /// The main accent: tabs, switches, the selected source, the record button.
    static let accent = dynamic(light: 0x3366F0, dark: 0x6F9CFF)
    /// The far end of the accent gradient.
    static let cyan = dynamic(light: 0x0B9FC2, dark: 0x4FD9EC)
    /// Words to say aloud in an answer: bright enough to find at a glance, dark enough to read on white.
    static let quote = dynamic(light: 0x2457D6, dark: 0x8FBBFF)

    static var gradient: LinearGradient {
        LinearGradient(colors: [accent, cyan], startPoint: .leading, endPoint: .trailing)
    }

    /// A hairline for surfaces that float over other apps: lit at the top, fading toward the bottom.
    static var floatingEdge: LinearGradient {
        LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0.06), .white.opacity(0.03)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// A gradient hairline for the thing that matters now, such as the newest answer.
    static var activeEdge: LinearGradient {
        LinearGradient(colors: [accent.opacity(0.75), cyan.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let cardRadius: CGFloat = 12
    static let floatingRadius: CGFloat = 16

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

extension View {
    /// A quiet card: a faint fill and a hairline, with a gradient edge and soft glow when it's the active one.
    func lukaCard(active: Bool = false) -> some View {
        padding(12)
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: LukaTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LukaTheme.cardRadius, style: .continuous)
                    .strokeBorder(active ? AnyShapeStyle(LukaTheme.activeEdge) : AnyShapeStyle(.primary.opacity(0.08)),
                                  lineWidth: active ? 1 : 0.5)
            }
            .modifier(LukaGlow(on: active))
    }

    /// The edge every floating surface shares: captions, the assistant card and its button.
    func lukaFloatingEdge<S: InsettableShape>(_ shape: S) -> some View {
        overlay { shape.strokeBorder(LukaTheme.floatingEdge, lineWidth: 0.75) }
    }
}

/// A soft accent glow, only drawn when on, so quiet cards cost nothing extra.
private struct LukaGlow: ViewModifier {
    let on: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if on {
            content.shadow(color: LukaTheme.accent.opacity(0.18), radius: 10, y: 2)
        } else {
            content
        }
    }
}
