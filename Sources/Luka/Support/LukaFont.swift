import AppKit
import SwiftUI

/// The text font for captions, the transcript and the summary: the system font, or a family the user picked.
enum LukaFont {
    static func ns(_ family: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard !family.isEmpty else { return .systemFont(ofSize: size, weight: weight) }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// The same font captions are measured with, so wrapping and drawing agree.
    static func font(_ family: String, size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        if family.isEmpty {
            let w: Font.Weight = weight == .semibold ? .semibold : weight == .medium ? .medium : weight == .bold ? .bold : .regular
            return .system(size: size, weight: w)
        }
        return Font(ns(family, size: size, weight: weight) as CTFont)
    }

    /// Installed families, without the system's hidden ones.
    static var families: [String] {
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
    }
}

extension EnvironmentValues {
    /// The chosen text font family; empty is the system font.
    @Entry var fontFamily: String = ""
}
