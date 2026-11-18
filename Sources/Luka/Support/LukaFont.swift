import AppKit
import SwiftUI

/// The text font for captions, the transcript and the summary: the system font or a family the user
/// picked, with an optional separate font for Chinese and Japanese characters.
enum LukaFont {
    /// The font for Chinese and Japanese characters; empty lets macOS pick (PingFang for Chinese).
    nonisolated(unsafe) static var cjkFamily = ""

    static func ns(_ family: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        var base: NSFont = .systemFont(ofSize: size, weight: weight)
        if !family.isEmpty {
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: family,
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
            ])
            base = NSFont(descriptor: descriptor, size: size) ?? base
        }
        guard !cjkFamily.isEmpty else { return base }
        // Latin text keeps the main font; characters it lacks come from the chosen CJK font first.
        let cjk = NSFontDescriptor(fontAttributes: [
            .family: cjkFamily,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        let cascaded = base.fontDescriptor.addingAttributes([.cascadeList: [cjk]])
        return NSFont(descriptor: cascaded, size: size) ?? base
    }

    /// The same font captions are measured with, so wrapping and drawing agree.
    static func font(_ family: String, size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        if family.isEmpty && cjkFamily.isEmpty {
            let w: Font.Weight = switch weight {
            case .light: .light
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            default: .regular
            }
            return .system(size: size, weight: w)
        }
        return Font(ns(family, size: size, weight: weight) as CTFont)
    }

    /// Installed families, without the system's hidden ones.
    static var families: [String] {
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
    }

    /// Installed families that have Chinese characters.
    static var cjkFamilies: [String] {
        families.filter { family in
            guard let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: family]), size: 13) else { return false }
            return font.coveredCharacterSet.contains(UnicodeScalar(0x4E2D)!)  // 中
        }
    }
}

/// How heavy caption text is.
enum CaptionWeight: String, CaseIterable, Sendable {
    case light, regular, medium

    var ns: NSFont.Weight {
        switch self {
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        }
    }
}

extension EnvironmentValues {
    /// The chosen text font family; empty is the system font.
    @Entry var fontFamily: String = ""
}
