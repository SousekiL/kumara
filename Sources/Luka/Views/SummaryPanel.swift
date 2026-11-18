import LukaCore
import SwiftUI

/// The column beside the transcript: the live summary, answers to the questions heard, or both.
struct SummaryPanel: View {
    @Environment(AppModel.self) private var model
    let transcript: Transcript
    /// How many answers the user has had in view; the rest count as new on the tab.
    @State private var seenAnswers = 0
    @State private var notesPosition = ScrollPosition(edge: .top)
    @State private var followingNotes = true

    private var summarizer: Summarizer { model.summarizer }
    private var answerer: Answerer { model.answerer }

    var body: some View {
        @Bindable var answerer = model.answerer
        @Bindable var summarizer = model.summarizer
        let mode = model.assistantMode
        let unseen = max(0, transcript.answers.count - seenAnswers)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                PanelTab(title: tr("Summary"), selected: !answerer.panelShowsAnswers, badge: false) {
                    answerer.panelShowsAnswers = false
                }
                PanelTab(title: tr("Answers"), selected: answerer.panelShowsAnswers, badge: unseen > 0 || answerer.live?.text != nil) {
                    answerer.panelShowsAnswers = true
                }
                Spacer(minLength: 4)
                // The kind of conversation: choosing one sets which helpers are on.
                ModeChip()
            }
            .padding(.horizontal, Self.inset)
            .frame(height: 40)
            if answerer.panelShowsAnswers {
                bar { answersStatus } actions: {
                    ProgressView().controlSize(.small).opacity(answerer.working ? 1 : 0)
                    Toggle("", isOn: $answerer.enabled)
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .help(tr("Answer questions as they’re asked"))
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { answers }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Self.inset)
                        .padding(.vertical, 16)
                }
                .onChange(of: transcript.answers.count, initial: true) { seenAnswers = transcript.answers.count }
            } else {
                bar { summaryStatus } actions: {
                    ProgressView().controlSize(.small).opacity(summarizer.working ? 1 : 0)
                    Button { model.refreshSummary(transcript) } label: { Image(systemName: "arrow.clockwise") }
                        .help(tr("Write the notes again from the whole transcript"))
                        .disabled(!model.assistant.isConfigured || summarizer.working || transcript.lines.isEmpty)
                    Button { copy(transcript.summary?.text, notice: tr("Copied summary")) } label: { Image(systemName: "doc.on.doc") }
                        .help(tr("Copy Summary"))
                        .disabled(transcript.summary == nil)
                    Toggle("", isOn: $summarizer.enabled)
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .help(tr("Summarize while listening"))
                }
                Divider()
                ScrollView {
                    summary
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Self.inset)
                        .padding(.vertical, 16)
                }
                // Opening a session shows where the notes end; an overview reads from the top.
                .defaultScrollAnchor(mode.rewritesSummary ? .top : .bottom, for: .initialOffset)
                // Notes grow at the bottom: follow them, like the transcript, unless the reader has scrolled up.
                .scrollPosition($notesPosition)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
                } action: { _, atBottom in
                    followingNotes = atBottom
                }
                .onChange(of: transcript.summary?.text) {
                    // An overview is rewritten whole, so there is no bottom to follow.
                    guard followingNotes, !mode.rewritesSummary else { return }
                    notesPosition.scrollTo(edge: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Answers already there when a session opens aren't news.
        .onAppear { seenAnswers = transcript.answers.count }
        .onChange(of: transcript.id) { seenAnswers = transcript.answers.count }
    }

    /// Side margin for everything in the column, so headers and text share one left edge.
    static let inset: CGFloat = 16

    /// One row under the tabs: what this is and how fresh, with its actions on the right.
    private func bar(@ViewBuilder status: () -> some View, @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 10) {
            status()
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions()
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, Self.inset)
        .frame(height: 30)
        .padding(.vertical, 4)
    }

    private func copy(_ text: String?, notice: String) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.show(notice)
    }

    private func setupHint(_ text: String) -> some View {
        EmptyNote(symbol: "gearshape", text: text) {
            Button(tr("Open Settings…")) { model.openSettings() }
                .controlSize(.small)
        }
    }

    // MARK: Summary

    @ViewBuilder private var summaryStatus: some View {
        if let error = summarizer.lastError {
            Text(error).foregroundStyle(.red).help(error)
        } else if let summary = transcript.summary {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text(String(format: tr("Updated %@"), Self.ago(summary.updatedAt, now: context.date)))
            }
        } else if !summarizer.enabled {
            Text(tr("Off"))
        } else if model.assistant.isConfigured {
            Text(tr("Listening for the first few sentences…"))
        } else {
            Text(tr("No model set"))
        }
    }

    @ViewBuilder private var summary: some View {
        if let summary = transcript.summary {
            VStack(alignment: .leading, spacing: model.assistant.fontSize * 0.9) {
                if let context = summary.context, !context.isEmpty {
                    Text(context)
                        .font(LukaFont.font(model.fontFamily, size: max(11, model.assistant.fontSize - 1)))
                        .lineSpacing(model.assistant.fontSize * 0.25)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
                }
                // While listening, the lines just added stand out and the rest steps back.
                SummaryText(markdown: summary.text, fontSize: model.assistant.fontSize, family: model.fontFamily,
                            freshFrom: model.isLive(transcript) && model.isListening ? summary.freshLine : nil)
            }
        } else if !model.assistant.isConfigured {
            setupHint(tr("Pick a model for the summary in Settings › Assistant."))
        } else if !summarizer.enabled {
            EmptyNote(symbol: "text.alignleft", text: tr("The summary is off. Turn it on with the switch above."))
        } else {
            EmptyNote(symbol: "list.bullet.rectangle", text: tr("Notes appear here a few sentences in, and keep growing as the conversation goes on."))
        }
    }

    // MARK: Answers

    @ViewBuilder private var answersStatus: some View {
        if let error = answerer.lastError {
            Text(error).foregroundStyle(.red).help(error)
        } else if answerer.working {
            Text(tr("Answering…"))
        } else if !answerer.enabled {
            Text(tr("Off"))
        } else if model.assistantMode == .lecture {
            Text(tr("Not answering in Lecture mode"))
        } else if model.assistant.isConfigured {
            Text(answerer.knowledgeCharacters > 0 ? tr("Using your knowledge base") : tr("No knowledge base; the model answers on its own"))
        } else {
            Text(tr("No model set"))
        }
    }

    /// Without Me / Them, nothing tells the interviewer's questions from the reader's own for certain.
    @ViewBuilder private var channelHint: some View {
        if answerer.enabled, model.assistantMode == .interview, !model.splitsBySource {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("To answer only the interviewer’s questions and never your own, Luka needs to hear you and them separately."))
                Button(tr("Turn On Me / Them")) { model.separatesSpeakers = true }
                    .controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.12), in: .rect(cornerRadius: 8))
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder private var answers: some View {
        channelHint
        let rows = answerRows
        if !rows.isEmpty {
            // Newest first and at full strength; earlier ones step back.
            let newest = rows.first?.id
            VStack(alignment: .leading, spacing: 18) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 18) {
                        AnswerCard(row: row, fontSize: model.assistant.fontSize, family: model.fontFamily,
                                   askerColor: row.polish ? .secondary : model.speakerColor(asker(of: row.id), in: transcript)) {
                            copy(row.answer, notice: tr("Copied answer"))
                        }
                        .opacity(row.id == newest ? 1 : 0.7)
                        if row.id != rows.last?.id { Divider().opacity(0.6) }
                    }
                    // A new card slides in from the top; one being written becomes the finished card in place.
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
                }
            }
            .animation(.smooth(duration: 0.25), value: rows.map(\.id))
        } else if !model.assistant.isConfigured {
            setupHint(tr("Pick a model for the answers in Settings › Assistant."))
        } else if !answerer.enabled {
            EmptyNote(symbol: "bubble.left.and.text.bubble.right", text: tr("Answers are off. Turn them on with the switch above."))
        } else {
            EmptyNote(symbol: "questionmark.bubble", text: tr("When someone asks a question, a short answer and hints appear here."))
        }
    }

    /// The session's answers, newest first, led by the one being written.
    private var answerRows: [AnswerRow] {
        var rows = transcript.answers.reversed().map(AnswerRow.init)
        if let live = answerer.live, live.session == transcript.id, !rows.contains(where: { $0.id == live.id }) {
            rows.insert(AnswerRow(live), at: 0)
        }
        return rows
    }

    private func asker(of lineID: Int) -> SpeakerID? {
        transcript.lines.last(where: { $0.id == lineID })?.speaker
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return String(format: tr("%d s ago"), seconds) }
        if seconds < 3600 { return String(format: tr("%d min ago"), seconds / 60) }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// Renders the model's small Markdown subset: "## " headings, "- " bullets, inline **bold**.
/// Spacing scales with the text size: about 1.5 line height for reading (more room helps Chinese),
/// clear gaps between bullets, and headings set off above more than below so they belong to what follows.
struct SummaryText: View {
    let markdown: String
    let fontSize: Double
    let family: String
    /// The Chinese font, so a change redraws the text.
    var cjk: String = LukaFont.cjkFamily
    /// The first line of the latest addition; earlier lines are dimmed. Nil shows everything alike.
    var freshFrom: Int? = nil

    private enum Kind { case heading, bullet, text }

    private var lines: [(kind: Kind, text: String)] {
        markdown.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                return (.heading, String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces))
            }
            for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                return (.bullet, String(line.dropFirst(marker.count)))
            }
            return (.text, line)
        }
    }

    var body: some View {
        let lines = lines
        let leading = fontSize * 0.42
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                let old = freshFrom.map { index < $0 } ?? false
                Group {
                    switch line.kind {
                    case .heading:
                        Text(inline(line.text))
                            .font(LukaFont.font(family, size: fontSize + 1, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.top, index == 0 ? 0 : fontSize * 0.9)
                            .padding(.bottom, fontSize * 0.25)
                    case .bullet:
                        // A hanging indent: wrapped lines line up with the text, not the dot.
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(verbatim: "•")
                                .foregroundStyle(.tertiary)
                                .frame(width: fontSize * 0.95, alignment: .leading)
                            Text(inline(line.text))
                                .lineSpacing(leading)
                        }
                        .font(LukaFont.font(family, size: fontSize))
                    case .text:
                        Text(inline(line.text))
                            .font(LukaFont.font(family, size: fontSize))
                            .lineSpacing(leading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, index == lines.count - 1 ? 0 : fontSize * 0.45)
                .opacity(old ? 0.7 : 1)
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// What an answer card shows: a filed answer, or one still being written.
struct AnswerRow: Identifiable {
    let id: Int
    let question: String
    let answer: String?
    let kind: String?
    let fromKnowledge: Bool
    let polish: Bool
    let createdAt: Date?

    init(_ item: QuestionAnswer) {
        id = item.id
        question = item.question
        answer = item.answer
        kind = item.kind == "polish" ? nil : item.kind
        fromKnowledge = item.fromKnowledge
        polish = item.kind == "polish"
        createdAt = item.createdAt
    }

    init(_ live: Answerer.Live) {
        id = live.id
        question = live.question
        answer = live.text
        kind = live.kind
        fromKnowledge = live.fromKnowledge
        polish = live.polish
        createdAt = nil
    }

    var streaming: Bool { createdAt == nil }
}

/// One question and its answer: the question small, the gist to say first, then points to make,
/// with the words to borrow in the accent color so they can be found at a glance.
private struct AnswerCard: View {
    let row: AnswerRow
    let fontSize: Double
    let family: String
    let askerColor: Color
    let copy: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(askerColor).frame(width: 6, height: 6)
                // For a polish, the question line is what I said; show its start, not its last sentence.
                Text(row.polish ? tr("You said") + ": " + row.question : Questions.lastSentence(row.question) ?? row.question)
                    .font(LukaFont.font(family, size: max(11, fontSize - 2)))
                    .foregroundStyle(.secondary)
                    .lineSpacing(fontSize * 0.15)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(row.question)
            }
            if let answer = row.answer {
                AnswerText(markdown: answer, fontSize: fontSize, family: family)
            } else {
                // Not past the model's header yet: it may still decide this needs no answer.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(tr("Thinking…"))
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            footer
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if row.polish {
                KindTag(kind: "polish")
            } else if let kind = row.kind {
                KindTag(kind: kind)
            }
            if row.answer != nil, !row.polish {
                Label(row.fromKnowledge ? tr("From your knowledge base") : tr("Model’s own knowledge"),
                      systemImage: row.fromKnowledge ? "books.vertical" : "sparkles")
            }
            if let date = row.createdAt {
                Text(verbatim: "·")
                Text(date.formatted(date: .omitted, time: .shortened))
            } else if row.answer != nil {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            Button(action: copy) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help(tr("Copy Answer"))
                .opacity(hovering && !row.streaming ? 1 : 0)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    }
}

/// An answer's text. The first plain line is the gist and reads larger; quoted words
/// (the phrases to say) take the accent color.
struct AnswerText: View {
    let markdown: String
    let fontSize: Double
    let family: String
    /// The Chinese font, so a change redraws the text.
    var cjk: String = LukaFont.cjkFamily

    private enum Kind { case gist, bullet, text }

    private var lines: [(kind: Kind, text: String)] {
        var sawGist = false
        return markdown.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { line = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces) }
            for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                sawGist = true
                return (.bullet, String(line.dropFirst(marker.count)))
            }
            if !sawGist {
                sawGist = true
                return (.gist, line)
            }
            return (.text, line)
        }
    }

    var body: some View {
        let lines = lines
        VStack(alignment: .leading, spacing: fontSize * 0.5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Group {
                    switch line.kind {
                    case .gist:
                        Text(Self.styled(line.text))
                            .font(LukaFont.font(family, size: fontSize + 1, weight: .semibold))
                            .lineSpacing(fontSize * 0.3)
                    case .bullet:
                        // A hanging indent: wrapped lines line up with the text, not the dot.
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(verbatim: "•")
                                .foregroundStyle(.tertiary)
                                .frame(width: fontSize * 0.95, alignment: .leading)
                            Text(Self.styled(line.text))
                                .lineSpacing(fontSize * 0.35)
                        }
                        .font(LukaFont.font(family, size: fontSize))
                    case .text:
                        Text(Self.styled(line.text))
                            .font(LukaFont.font(family, size: fontSize))
                            .lineSpacing(fontSize * 0.35)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }

    /// Inline Markdown, with text in quotes in the accent color.
    static func styled(_ s: String) -> AttributedString {
        var text = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        let pairs: [(open: Character, close: Character)] = [("\"", "\""), ("“", "”"), ("「", "」")]
        let chars = Array(text.characters)
        var i = 0
        while i < chars.count {
            if let pair = pairs.first(where: { $0.open == chars[i] }),
               i + 1 < chars.count,
               let close = chars[(i + 1)...].firstIndex(of: pair.close) {
                let lower = text.characters.index(text.startIndex, offsetBy: i)
                let upper = text.characters.index(text.startIndex, offsetBy: close + 1)
                text[lower..<upper].foregroundColor = Color.accentColor
                i = close + 1
            } else {
                i += 1
            }
        }
        return text
    }
}

/// A question's kind, as a small colored tag.
private struct KindTag: View {
    let kind: String

    var body: some View {
        let color = QuestionKind.color(kind)
        Text(QuestionKind.title(kind))
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.16), in: .capsule)
    }
}

/// What an empty column says: a quiet symbol and one line, centered, with an optional action.
private struct EmptyNote<Action: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            action()
        }
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }
}

extension EmptyNote where Action == EmptyView {
    init(symbol: String, text: String) {
        self.init(symbol: symbol, text: text) { EmptyView() }
    }
}

/// A tab in the column's header: plain text, underlined when chosen.
private struct PanelTab: View {
    let title: String
    let selected: Bool
    let badge: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    // Both weights take the same room, so choosing a tab never shifts the header.
                    .fontWeight(.semibold).opacity(0)
                    .overlay { Text(title).fontWeight(selected ? .semibold : .regular) }
                // Always there, so the label never changes width.
                Circle().fill(Color.accentColor).frame(width: 5, height: 5).opacity(badge && !selected ? 1 : 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                Capsule().fill(Color.accentColor).frame(height: 2).padding(.trailing, 9).opacity(selected ? 1 : 0).offset(y: 3)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The mode, as a small menu in the header.
private struct ModeChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("", selection: $model.assistantMode) {
                ForEach(AssistantMode.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.assistantMode.symbol)
                Text(model.assistantMode.title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.primary.opacity(0.08), in: .capsule)
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.assistantMode.explanation)
    }
}

extension AssistantMode {
    var title: String {
        switch self {
        case .lecture: tr("Lecture")
        case .meeting: tr("Meeting")
        case .interview: tr("Interview")
        }
    }

    var symbol: String {
        switch self {
        case .lecture: "graduationcap"
        case .meeting: "person.3"
        case .interview: "person.2"
        }
    }

    var explanation: String {
        switch self {
        case .lecture: tr("Talks, lectures, podcasts and videos: one structured summary, rewritten as the talk goes on. No answers. Turns the summary, answers and Me / Them off; turn the summary on for an overview.")
        case .meeting: tr("Meetings and calls: running notes added in order, with decisions and tasks marked. Only factual or technical questions get a short answer. Turns on the summary and Me / Them, with each other person numbered; answers off.")
        case .interview: tr("Interviews: interview questions for your role answered in the first person, and your own answers polished; running notes of each question if you turn the summary on. Turns on answers, Me / Them, the pinned question and polishing; the summary off.")
        }
    }
}

enum QuestionKind {
    static func title(_ kind: String) -> String {
        switch kind {
        case "technical": tr("Technical")
        case "case": tr("Case")
        case "behavioral": tr("Behavioral")
        case "experience": tr("Experience")
        case "motivation": tr("Motivation")
        case "reverse": tr("Your questions")
        case "polish": tr("Polish")
        default: kind
        }
    }

    static func color(_ kind: String) -> Color {
        switch kind {
        case "technical": .blue
        case "case": .purple
        case "behavioral": .orange
        case "experience": .green
        case "motivation": .pink
        case "polish": .teal
        default: .gray
        }
    }
}
