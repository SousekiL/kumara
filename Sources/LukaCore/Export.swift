import Foundation

extension Transcript {
    /// Markdown export. `name` resolves a speaker to its display name.
    public func markdown(title: String, name: (SpeakerID) -> String, includeOriginal: Bool) -> String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        var out = "# \(title)\n"
        if let summary, !summary.text.isEmpty {
            // The summary's own sections sit one level below the export's.
            let body = summary.text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.hasPrefix("## ") ? "###" + $0.dropFirst(2) : String($0) }
                .joined(separator: "\n")
            let context = summary.context.map { "_\($0)_\n\n" } ?? ""
            out += "\n## Summary\n\n\(context)\(body)\n\n---\n"
        }
        for turn in turns {
            let who = turn.speaker.map(name) ?? "—"
            let when = turn.lines.first.map { time.string(from: $0.startedAt) } ?? ""
            out += "\n**\(who)** · \(when)\n\n"
            for line in turn.lines {
                if line.expectsTranslation {
                    out += line.translations.map(\.text).joined(separator: "  \n") + "\n"
                    if includeOriginal { out += "> \(line.original)\n" }
                } else {
                    out += "\(line.original)\n"
                }
                out += "\n"
            }
        }
        return out
    }

    /// Plain text for the clipboard: who, when, what was said.
    public func plainText(name: (SpeakerID) -> String, includeOriginal: Bool) -> String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        var blocks: [String] = []
        for turn in turns {
            var block = "[\(turn.lines.first.map { time.string(from: $0.startedAt) } ?? "")] \(turn.speaker.map(name) ?? "—")"
            for line in turn.lines {
                block += "\n" + line.primary
                if includeOriginal && line.expectsTranslation && !line.original.isEmpty { block += "\n  " + line.original }
            }
            blocks.append(block)
        }
        return blocks.joined(separator: "\n\n")
    }
}
