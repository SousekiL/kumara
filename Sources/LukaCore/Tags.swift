import Foundation

/// Tags on sessions: short labels the user types, compared without regard to case.
public enum Tags {
    public static let maxLength = 32

    /// A typed tag cleaned up: trimmed, without a leading #, inner spaces collapsed. Nil when nothing is left.
    public static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("#") || s.hasPrefix("＃") { s.removeFirst() }
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !s.isEmpty else { return nil }
        return String(s.prefix(maxLength))
    }

    /// Whether two tags are the same tag.
    public static func same(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// `tags` with `tag` added, unless it's already there in any case.
    public static func adding(_ tag: String, to tags: [String]) -> [String] {
        guard let tag = normalize(tag), !tags.contains(where: { same($0, tag) }) else { return tags }
        return tags + [tag]
    }

    /// `tags` without `tag`, in any case.
    public static func removing(_ tag: String, from tags: [String]) -> [String] {
        tags.filter { !same($0, tag) }
    }

    /// Every tag in use, most used first, then alphabetically. One spelling per tag: the first seen.
    public static func all(in lists: [[String]]) -> [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for list in lists {
            for tag in list {
                let key = tag.lowercased()
                counts[key, default: (tag, 0)].count += 1
            }
        }
        return counts.values
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(\.name)
    }
}
