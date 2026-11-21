import LukaCore
import SwiftUI

/// The column beside the transcript: the live summary, answers to the questions heard, or both.
struct SummaryPanel: View {
    @Environment(AppModel.self) private var model
    let transcript: Transcript
    /// Just the answers, for under the captions: no tabs, no summary, no ask box.
    var answersOnly = false
    /// How many answers the user has had in view; the rest count as new on the tab.
    @State private var seenAnswers = 0
    @State private var notesPosition = ScrollPosition(edge: .top)
    @State private var followingNotes = true

    private var summarizer: Summarizer { model.summarizer }
    private var answerer: Answerer { model.answerer }

    var body: some View {
        if answersOnly {
            VStack(spacing: 0) { answersSection(titled: true) }
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            column
        }
    }

    @ViewBuilder private var column: some View {
        @Bindable var answerer = model.answerer
        let unseen = max(0, transcript.answers.count - seenAnswers)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                if !model.panelStacked {
                    PanelTab(title: tr("Summary"), selected: !answerer.panelShowsAnswers, badge: false) {
                        answerer.panelShowsAnswers = false
                    }
                    PanelTab(title: tr("Answers"), selected: answerer.panelShowsAnswers, badge: unseen > 0 || answerer.live?.text != nil) {
                        answerer.panelShowsAnswers = true
                    }
                }
                Spacer(minLength: 4)
                // Tabs, or the summary above the answers so both are in view at once.
                Button { model.panelStacked.toggle() } label: {
                    Image(systemName: model.panelStacked ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
                        .foregroundStyle(model.panelStacked ? AnyShapeStyle(LukaTheme.accent) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.borderless)
                .help(model.panelStacked ? tr("Show summary and answers as tabs") : tr("Show summary above answers"))
                // The kind of conversation: choosing one sets which helpers are on.
                ModeChip()
            }
            .padding(.horizontal, Self.inset)
            .frame(height: 40)
            if model.panelStacked {
                // Both at once; the answers get the larger share, and the divider drags.
                StackedSplit(fraction: Bindable(model).panelSplit) {
                    summarySection(titled: true)
                } bottom: {
                    answersSection(titled: true)
                }
            } else if answerer.panelShowsAnswers {
                answersSection(titled: false)
            } else {
                summarySection(titled: false)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Ask anything about this session, from either tab; the answer shows under Answers.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AskBar(transcript: transcript)
        }
        // Answers already there when a session opens aren't news.
        .onAppear { seenAnswers = transcript.answers.count }
        .onChange(of: transcript.id) { seenAnswers = transcript.answers.count }
    }

    /// Side margin for everything in the column, so headers and text share one left edge.
    static let inset: CGFloat = 16

    @ViewBuilder private func answersSection(titled: Bool) -> some View {
        @Bindable var answerer = model.answerer
        bar(title: titled ? tr("Answers") : nil) { answersStatus } actions: {
            ProgressView().controlSize(.small).opacity(answerer.working ? 1 : 0)
            if answersOnly {
                // Under the captions, a way back that's always in sight: the caption toolbar
                // only appears on hover, which the scrolling answers don't always pass on.
                Menu {
                    Picker(tr("Show"), selection: Bindable(model).captionLayout) {
                        ForEach(CaptionContent.allCases, id: \.self) { layout in
                            Label(layout.title, systemImage: layout.symbol).tag(layout)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: model.captionLayout.symbol)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("Captions and answers"))
            }
            Toggle("", isOn: $answerer.enabled)
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .help(tr("Answer questions as they’re asked"))
        }
        // Under the captions, the header is where the caption window is dragged from.
        .windowDraggable(answersOnly)
        Divider()
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { answers }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Self.inset)
                .padding(.vertical, 16)
        }
        .onChange(of: transcript.answers.count, initial: true) { seenAnswers = transcript.answers.count }
    }

    @ViewBuilder private func summarySection(titled: Bool) -> some View {
        @Bindable var summarizer = model.summarizer
        bar(title: titled ? tr("Summary") : nil) { summaryStatus } actions: {
            ProgressView().controlSize(.small).opacity(summarizer.working || summarizer.recapping ? 1 : 0)
            // One request, only when pressed: what was just said, for when attention slipped.
            Button { model.catchMeUp(transcript) } label: { Image(systemName: "clock.arrow.circlepath") }
                .help(tr("Catch me up: what was just said"))
                .disabled(!model.assistant.isConfigured || summarizer.recapping || transcript.lines.isEmpty)
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
        // Opening a session shows where the notes end.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // Notes grow at the bottom: follow them, like the transcript, unless the reader has scrolled up.
        .scrollPosition($notesPosition)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
        } action: { _, atBottom in
            followingNotes = atBottom
        }
        .onChange(of: transcript.summary?.text) {
            guard followingNotes else { return }
            notesPosition.scrollTo(edge: .bottom)
        }
    }

    /// One row under the tabs: what this is and how fresh, with its actions on the right.
    private func bar(title: String? = nil, @ViewBuilder status: () -> some View, @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).fixedSize()
            }
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

    /// The mode this session is in: the current mode while it's live, the saved one afterwards.
    /// Older sessions without one count as interviews when they have typed interview answers.
    private var sessionMode: AssistantMode? {
        if model.isLive(transcript) { return model.assistantMode }
        return transcript.mode ?? (transcript.answers.contains { $0.kind != nil && $0.kind != "asked" && $0.kind != "for-me" } ? .interview : nil)
    }

    @ViewBuilder private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let recap = summarizer.recap, recap.session == transcript.id {
                RecapCard(text: recap.text, at: recap.at, fontSize: model.assistant.fontSize, family: model.fontFamily) {
                    summarizer.dismissRecap()
                }
            }
            // In a meeting, what's been asked of me stays at the top, found without asking the model.
            if sessionMode == .meeting {
                let items = transcript.forMe(names: model.assistant.names)
                if !items.isEmpty { ForMeStrip(items: items, fontSize: model.assistant.fontSize, family: model.fontFamily) }
            }
            modeSummary
        }
    }

    @ViewBuilder private var modeSummary: some View {
        let log = sessionMode == .interview ? transcript.questionLog : []
        if !log.isEmpty || (sessionMode == .interview && transcript.summary == nil && !summarizer.enabled) {
            // In an interview the summary tab leads with the questions asked and how each went;
            // it costs nothing, since it is built from the answers and polishes already made.
            VStack(alignment: .leading, spacing: 16) {
                QuestionTracker(log: log, fontSize: model.assistant.fontSize, family: model.fontFamily)
                if transcript.summary != nil { Divider() }
                notes
            }
        } else {
            notes
        }
    }

    @ViewBuilder private var notes: some View {
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
                let terms = KeyTerm.all(in: summary.text)
                if !terms.isEmpty {
                    KeyTermsBox(terms: terms, fontSize: model.assistant.fontSize, family: model.fontFamily)
                }
                // While listening, the lines just added stand out and the rest steps back.
                SummaryText(markdown: summary.text, fontSize: model.assistant.fontSize, family: model.fontFamily,
                            freshFrom: model.isLive(transcript) && model.isListening ? summary.freshLine : nil)
            }
        } else if !model.assistant.isConfigured {
            setupHint(tr("Pick a model for the summary in Settings › Models."))
        } else if !summarizer.enabled {
            if sessionMode != .interview {
                EmptyNote(symbol: "text.alignleft", text: tr("The summary is off. Turn it on with the switch above."))
            }
        } else {
            EmptyNote(symbol: "list.bullet.rectangle", text: tr("Notes appear here a few sentences in, and keep growing as the conversation goes on."))
        }
    }

    // MARK: Answers

    @ViewBuilder private var answersStatus: some View {
        if let error = answerer.lastError {
            Text(error).foregroundStyle(.red).help(error)
        } else if let live = answerer.live, live.session == transcript.id, !live.polish, !live.committed {
            // Deciding whether it needs an answer at all.
            Text(tr("Checking") + ": " + (Questions.lastSentence(live.question) ?? live.question)).help(live.question)
        } else if answerer.working {
            Text(tr("Answering…"))
        } else if !answerer.enabled {
            Text(tr("Off"))
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
                Text(tr("To answer only the interviewer’s questions and never your own, Kumara needs to hear you and them separately."))
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
        // What was judged to need no answer, with a way to answer it anyway.
        if let s = answerer.skipped, s.session == transcript.id, answerer.live == nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.uturn.right").foregroundStyle(.tertiary)
                Text(tr("Skipped, didn’t look like it needs an answer") + ": " + (Questions.lastSentence(s.question) ?? s.question))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(s.question)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(tr("Answer anyway")) { model.answerAnyway(transcript) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(LukaTheme.accent)
            }
            .font(.caption)
            .padding(.bottom, 12)
            .transition(.opacity)
        }
        let rows = answerRows
        let askers = askers(of: Set(rows.filter { !$0.polish && !$0.asked }.map(\.id)))
        if !rows.isEmpty {
            // Newest first and at full strength; earlier ones step back.
            let newest = rows.first?.id
            VStack(alignment: .leading, spacing: 12) {
                ForEach(rows) { row in
                    AnswerCard(row: row, fontSize: model.assistant.fontSize, family: model.fontFamily,
                               askerColor: row.polish ? .secondary : row.asked ? LukaTheme.accent : model.speakerColor(askers[row.id], in: transcript)) {
                        copy(row.answer, notice: tr("Copied answer"))
                    }
                    // The newest card carries the accent edge; earlier ones are quieter cards.
                    .lukaCard(active: row.id == newest)
                    .opacity(row.id == newest ? 1 : 0.78)
                    // A new card slides in from the top; one being written becomes the finished card in place.
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
                }
            }
            .animation(.smooth(duration: 0.25), value: rows.map(\.id))
        } else if !model.assistant.isConfigured {
            setupHint(tr("Pick a model for the answers in Settings › Models."))
        } else if !answerer.enabled {
            EmptyNote(symbol: "bubble.left.and.text.bubble.right", text: tr("Answers are off. Turn them on with the switch above."))
        } else {
            EmptyNote(symbol: "questionmark.bubble", text: tr("When someone asks a question, a short answer and hints appear here."))
        }
    }

    /// The session's answers, newest first, led by the one being written.
    private var answerRows: [AnswerRow] {
        // A polish with nothing to fix only feeds the question tracker.
        var rows = transcript.answers.reversed().filter { !($0.kind == "polish" && $0.answer.isEmpty) }.map(AnswerRow.init)
        // A polish shows only once it has a fix; most of its reply is for the tracker and the review.
        // A heard question shows only once the model commits to answering it: until then it may
        // still judge that it needs none, and a card that appears and vanishes is just noise.
        if let live = answerer.live, live.session == transcript.id, live.polish ? live.text != nil : live.committed,
           !rows.contains(where: { $0.id == live.id }) {
            rows.insert(AnswerRow(live), at: 0)
        }
        // A question the reader asked shows at once, above everything, while it's answered.
        if let asking = answerer.asking, asking.session == transcript.id, !rows.contains(where: { $0.id == asking.id }) {
            rows.insert(AnswerRow(asking), at: 0)
        }
        return rows
    }

    /// Who asked each answered question, found in one pass over the lines.
    private func askers(of ids: Set<Int>) -> [Int: SpeakerID] {
        var out: [Int: SpeakerID] = [:]
        for line in transcript.lines where ids.contains(line.id) { out[line.id] = line.speaker }
        return out
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
        // Term lines are gathered in the key-terms box instead; the others keep their place in the count,
        // so the fresh lines are still found by index.
        let lines = Array(lines.enumerated()).filter { !KeyTerm.isTermLine($0.element.text) || $0.element.kind != .bullet }
        let leading = fontSize * 0.42
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.offset) { index, entry in
                let line = entry.element
                let old = freshFrom.map { entry.offset < $0 } ?? false
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
        var text = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        Self.colorTags(&text)
        return text
    }

    /// Meeting tags in the notes, each in its own color so decisions, tasks and open questions can be scanned.
    static func colorTags(_ text: inout AttributedString) {
        let plain = String(text.characters)
        let tags: [(prefix: String, color: Color)] = [
            ("[Decision]", .green), ("[Action", LukaTheme.accent), ("[Open", .orange), ("[Number]", .purple), ("↺", .orange),
        ]
        for tag in tags {
            var search = plain.startIndex..<plain.endIndex
            while let found = plain.range(of: tag.prefix, options: .caseInsensitive, range: search) {
                // A bracket tag runs to its closing bracket; ↺ is a single mark.
                let end = tag.prefix.hasPrefix("[") ? (plain[found.lowerBound...].firstIndex(of: "]").map { plain.index(after: $0) } ?? found.upperBound) : found.upperBound
                let lower = plain.distance(from: plain.startIndex, to: found.lowerBound)
                let length = plain.distance(from: found.lowerBound, to: end)
                let a = text.characters.index(text.startIndex, offsetBy: lower)
                let b = text.characters.index(a, offsetBy: length)
                text[a..<b].foregroundColor = tag.color
                text[a..<b].font = .system(size: 11, weight: .semibold)
                search = end..<plain.endIndex
            }
        }
    }
}

/// The terms a lecture introduced, gathered from the notes: closed to a count until opened.
private struct KeyTermsBox: View {
    let terms: [KeyTerm]
    let fontSize: Double
    let family: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.smooth(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "character.book.closed")
                    Text(String(format: tr("Key terms (%d)"), terms.count))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(LukaTheme.accent)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                ForEach(terms) { term in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(term.term).font(LukaFont.font(family, size: max(11, fontSize - 1), weight: .semibold))
                            if let gloss = term.gloss {
                                Text(gloss).font(LukaFont.font(family, size: max(11, fontSize - 1))).foregroundStyle(.secondary)
                            }
                        }
                        if let definition = term.definition {
                            Text(definition)
                                .font(LukaFont.font(family, size: max(11, fontSize - 2)))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
        .lukaCard()
    }
}

/// A "catch me up" reply, dismissible, above the notes.
private struct RecapCard: View {
    let text: String
    let at: Date
    let fontSize: Double
    let family: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(tr("Catch me up"), systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LukaTheme.accent)
                Text(at.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help(tr("Close"))
            }
            AnswerText(markdown: text, fontSize: fontSize, family: family)
        }
        .lukaCard(active: true)
    }
}

/// In a meeting: lines that mention me by name, and tasks the notes give me.
private struct ForMeStrip: View {
    let items: [ForMeItem]
    let fontSize: Double
    let family: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(tr("For you"), systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: item.kind == .mention ? "quote.bubble" : "checklist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.text)
                        .font(LukaFont.font(family, size: max(11, fontSize - 1)))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: .rect(cornerRadius: LukaTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LukaTheme.cardRadius, style: .continuous).strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
        }
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
    /// A question the reader typed, and what its answer rests on.
    let asked: Bool
    let source: String?
    let restated: String?
    let createdAt: Date?

    init(_ item: QuestionAnswer) {
        id = item.id
        question = item.question
        answer = item.answer
        kind = item.kind == "polish" || item.kind == "asked" ? nil : item.kind
        fromKnowledge = item.fromKnowledge
        polish = item.kind == "polish"
        asked = item.kind == "asked"
        source = item.source
        restated = item.restated
        createdAt = item.createdAt
    }

    init(_ live: Answerer.Live) {
        id = live.id
        question = live.question
        answer = live.text
        kind = live.kind
        fromKnowledge = live.fromKnowledge
        polish = live.polish
        asked = live.asked
        source = live.source
        restated = live.restated
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
                Text(row.polish ? tr("You said") + ": " + row.question
                     : row.asked ? tr("You asked") + ": " + row.question
                     : row.restated ?? Questions.lastSentence(row.question) ?? row.question)
                    .font(LukaFont.font(family, size: max(11, fontSize - 2), weight: row.asked ? .medium : .regular))
                    .foregroundStyle(row.asked ? .primary : .secondary)
                    .lineSpacing(fontSize * 0.15)
                    .lineLimit(row.asked ? 4 : 3)
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
            if row.asked, row.answer != nil {
                switch row.source {
                case "transcript": Label(tr("From this conversation"), systemImage: "text.bubble")
                case "knowledge": Label(tr("From your knowledge base"), systemImage: "books.vertical")
                default: Label(tr("Model’s own knowledge"), systemImage: "sparkles")
                }
            } else if row.answer != nil, !row.polish {
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

    private enum Kind { case gist, bullet, cue(String), anchor, text }

    private var lines: [(kind: Kind, text: String)] {
        var sawGist = false
        return markdown.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { line = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces) }
            for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                sawGist = true
                return (.bullet, String(line.dropFirst(marker.count)))
            }
            // An interview skeleton: numbered cues, then the anchor from the reader's own material.
            if let first = line.first, "①②③④⑤".contains(first) {
                sawGist = true
                return (.cue(String(first)), String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
            if line.hasPrefix("⚓") {
                sawGist = true
                return (.anchor, String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
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
                    case .cue(let mark):
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: mark)
                                .foregroundStyle(LukaTheme.accent)
                            Text(Self.styled(line.text))
                                .lineSpacing(fontSize * 0.3)
                        }
                        .font(LukaFont.font(family, size: fontSize))
                    case .anchor:
                        AnchorLine(text: line.text, fontSize: fontSize, family: family)
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
                text[lower..<upper].foregroundColor = LukaTheme.quote
                i = close + 1
            } else {
                i += 1
            }
        }
        return text
    }
}

/// The answer's anchor: the reader's own project, story or number, with the file it came from.
private struct AnchorLine: View {
    let text: String
    let fontSize: Double
    let family: String

    var body: some View {
        let none = text.isEmpty || text == "—" || text == "-"
        let file = Self.file(in: text)
        let rest = Self.rest(of: text)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "pin.fill")
                .font(.system(size: max(9, fontSize - 4)))
                .foregroundStyle(none ? AnyShapeStyle(.tertiary) : AnyShapeStyle(LukaTheme.cyan))
            if none {
                Text(tr("Nothing in your knowledge base fits: pick a story of this kind."))
                    .foregroundStyle(.secondary)
            } else {
                (file.map { Text(verbatim: $0 + "  ").foregroundStyle(.tertiary) } ?? Text(verbatim: ""))
                    + Text(AnswerText.styled(rest))
            }
        }
        .font(LukaFont.font(family, size: max(11, fontSize - 1)))
        .lineSpacing(fontSize * 0.25)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LukaTheme.cyan.opacity(none ? 0.04 : 0.09), in: .rect(cornerRadius: 7))
    }

    /// "[projects.md] Search holdout": the file name in front, read as a quiet label.
    static func file(in text: String) -> String? {
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return nil }
        return String(text[text.index(after: text.startIndex)..<close])
    }

    static func rest(of text: String) -> String {
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return text }
        return String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
    }
}

/// Interview questions in order, each with whether my answer covered it and what I used,
/// so the same story isn't told twice and "as I mentioned earlier" stays true.
private struct QuestionTracker: View {
    let log: [QuestionLogEntry]
    let fontSize: Double
    let family: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Questions so far"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if log.isEmpty {
                Text(tr("Each interview question shows here with how your answer went and the story you used."))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(log.enumerated()), id: \.element.id) { index, entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if let kind = entry.question.kind { KindTag(kind: kind) }
                            status(entry.status)
                        }
                        .font(.caption)
                        Text(entry.question.shownQuestion)
                            .font(LukaFont.font(family, size: max(11, fontSize - 1)))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(entry.question.question)
                        if !entry.used.isEmpty {
                            Text(tr("Used") + ": " + entry.used.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func status(_ status: String?) -> some View {
        switch status {
        case "complete":
            Label(tr("Answered"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case "partial":
            Label(tr("Missed a part"), systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
        default:
            Label(tr("Not reviewed yet"), systemImage: "circle.dotted").foregroundStyle(.tertiary)
        }
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

/// The box at the bottom of the column for asking about this session.
private struct AskBar: View {
    @Environment(AppModel.self) private var model
    let transcript: Transcript
    @State private var draft = ""
    @FocusState private var focused: Bool
    /// The background editor is open.
    @State private var editingBackground = false
    /// When the draft was last filed as background, for the note that says so.
    @State private var filedAt: Date?

    var body: some View {
        @Bindable var transcript = transcript
        let ready = model.assistant.isAskConfigured
        let hasBackground = SessionBackground.isWritten(transcript.background)
        let busy = model.answerer.asking?.session == transcript.id
        let failure = model.answerer.askFailure.flatMap { $0.session == transcript.id ? $0 : nil }
        VStack(spacing: 0) {
            Divider()
            if let failure {
                Text(failure.error)
                    .font(.caption).foregroundStyle(.red).lineLimit(2).help(failure.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SummaryPanel.inset).padding(.top, 8)
            } else if filedAt != nil {
                Text(tr("Added to this conversation’s background"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SummaryPanel.inset).padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { editingBackground = true } label: {
                    Image(systemName: hasBackground ? "doc.text.fill" : "doc.text")
                        .font(.system(size: 14))
                        .foregroundStyle(hasBackground ? AnyShapeStyle(LukaTheme.accent) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .frame(width: 22, height: 22)
                .help(tr("Background for this conversation") + "  ·  " + tr("⌘↩ adds what you typed"))
                .popover(isPresented: $editingBackground, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("Background for this conversation")).font(.headline)
                        Text(tr("Who’s there, what it’s about, what you want from the notes. Used for this conversation’s notes, answers and questions."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        TextEditor(text: $transcript.background)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
                            .frame(height: 170)
                    }
                    .padding(14)
                    .frame(width: 340)
                }
                TextField("", text: $draft,
                          prompt: Text(ready ? tr("Ask about this conversation…") : tr("Pick a model in Settings › Models to ask questions")),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($focused)
                    .disabled(!ready)
                    .onSubmit(send)
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        file()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard !draft.isEmpty else { return .ignored }
                        draft = ""
                        return .handled
                    }
                Group {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(canSend ? AnyShapeStyle(LukaTheme.accent) : AnyShapeStyle(.tertiary))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help(tr("Ask") + "  ↩")
                    }
                }
                .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focused ? AnyShapeStyle(LukaTheme.accent.opacity(0.7)) : AnyShapeStyle(Color.primary.opacity(0.18)),
                                  lineWidth: 0.75)
            }
            .padding(.horizontal, SummaryPanel.inset - 4)
            .padding(.vertical, 10)
        }
        // A frosted backing so answers scrolling underneath don't show through the box,
        // above all on the see-through floating card.
        .background(.thickMaterial)
        // A question that failed comes back into the box to send again.
        .onChange(of: failure?.question) { _, question in
            if let question, draft.isEmpty { draft = question }
        }
    }

    private var canSend: Bool {
        model.assistant.isAskConfigured && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        model.ask(draft, in: transcript)
        draft = ""
    }

    /// Keeps what was typed as background for this session instead of asking it.
    private func file() {
        let added = SessionBackground.adding(draft, to: transcript.background)
        guard added != transcript.background else { return }
        transcript.background = added
        draft = ""
        let stamp = Date.now
        filedAt = stamp
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if filedAt == stamp { filedAt = nil }
        }
    }
}

extension View {
    /// Drags the window from this view's empty space, when on.
    @ViewBuilder func windowDraggable(_ on: Bool) -> some View {
        if on {
            self.contentShape(.rect).gesture(WindowDragGesture())
        } else {
            self
        }
    }
}

/// Two panes, one above the other, split at a fraction the reader drags.
private struct StackedSplit<Top: View, Bottom: View>: View {
    @Binding var fraction: Double
    @ViewBuilder var top: Top
    @ViewBuilder var bottom: Bottom
    @State private var start: Double?

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            VStack(spacing: 0) {
                VStack(spacing: 0) { top }
                    .frame(height: max(0, height * fraction - 4))
                    .clipped()
                // The handle: a line with room to grab it.
                ZStack {
                    Rectangle().fill(.clear)
                    Divider()
                    Capsule().fill(.tertiary).frame(width: 34, height: 4)
                }
                .frame(height: 8)
                .contentShape(.rect)
                .pointerStyle(.frameResize(position: .top))
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = start ?? fraction
                        if start == nil { start = base }
                        guard height > 0 else { return }
                        fraction = min(max(base + value.translation.height / height, 0.15), 0.85)
                    }
                    .onEnded { _ in start = nil })
                VStack(spacing: 0) { bottom }
                    .frame(maxHeight: .infinity)
                    .clipped()
            }
        }
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
                Circle().fill(LukaTheme.accent).frame(width: 5, height: 5).opacity(badge && !selected ? 1 : 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) {
                Capsule().fill(LukaTheme.gradient).frame(height: 2).padding(.trailing, 9).opacity(selected ? 1 : 0).offset(y: 3)
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
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.7)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(LukaTheme.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(LukaTheme.accent.opacity(0.12), in: .capsule)
            .overlay { Capsule().strokeBorder(LukaTheme.accent.opacity(0.28), lineWidth: 0.5) }
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
        case .transcribe: tr("Transcribe")
        case .lecture: tr("Lecture")
        case .meeting: tr("Meeting")
        case .interview: tr("Interview")
        }
    }

    var symbol: String {
        switch self {
        case .transcribe: "captions.bubble"
        case .lecture: "graduationcap"
        case .meeting: "person.3"
        case .interview: "person.2"
        }
    }

    var explanation: String {
        switch self {
        case .transcribe: tr("Transcription and translation only. Turns every helper off.")
        case .lecture: tr("Talks, lectures, podcasts and videos: notes in numbered sections that stay put once the talk moves on, with the key terms gathered above. Turns on the summary; everything else off.")
        case .meeting: tr("Meetings and calls: running notes added in order, with decisions and tasks marked. If you turn answers on, only factual or technical questions get a short answer. Turns on the summary; everything else off.")
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
        case "for-me": tr("For you")
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
        case "for-me": .indigo
        default: .gray
        }
    }
}
