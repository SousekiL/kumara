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
        let unseen = max(0, transcript.answers.count - seenAnswers)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $answerer.panelShowsAnswers) {
                    Text(tr("Summary")).tag(false)
                    // A fixed-width label: a count that comes and goes would resize the whole header.
                    Text(unseen > 0 ? tr("Answers") + " •" : tr("Answers")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer(minLength: 4)
                // The kind of conversation: how the summary is kept, how readily questions are answered.
                Picker("", selection: $summarizer.mode) {
                    ForEach(AssistantMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help(summarizer.mode.explanation)
            }
            .padding(.horizontal, Self.inset)
            .padding(.top, 10)
            .padding(.bottom, 2)
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
                        .padding(.vertical, 14)
                }
                .onChange(of: transcript.answers.count, initial: true) { seenAnswers = transcript.answers.count }
            } else {
                bar { summaryStatus } actions: {
                    ProgressView().controlSize(.small).opacity(summarizer.working ? 1 : 0)
                    Button { model.refreshSummary(transcript) } label: { Image(systemName: "arrow.clockwise") }
                        .help(tr("Write the notes again from the whole transcript"))
                        .disabled(!summarizer.isConfigured || summarizer.working || transcript.lines.isEmpty)
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
                        .padding(.vertical, 14)
                }
                // Opening a session shows where the notes end; an overview reads from the top.
                .defaultScrollAnchor(summarizer.mode.rewritesSummary ? .top : .bottom, for: .initialOffset)
                // Notes grow at the bottom: follow them, like the transcript, unless the reader has scrolled up.
                .scrollPosition($notesPosition)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
                } action: { _, atBottom in
                    followingNotes = atBottom
                }
                .onChange(of: transcript.summary?.text) {
                    // An overview is rewritten whole, so there is no bottom to follow.
                    guard followingNotes, !summarizer.mode.rewritesSummary else { return }
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
        VStack(alignment: .leading, spacing: 10) {
            Text(text).foregroundStyle(.secondary)
            Button(tr("Open Settings…")) { model.openSettings() }
        }
        .font(.callout)
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
        } else if summarizer.isConfigured {
            Text(tr("Listening for the first few sentences…"))
        } else {
            Text(tr("No model set"))
        }
    }

    @ViewBuilder private var summary: some View {
        if let summary = transcript.summary {
            VStack(alignment: .leading, spacing: summarizer.fontSize * 0.9) {
                if let context = summary.context, !context.isEmpty {
                    Text(context)
                        .font(LukaFont.font(model.fontFamily, size: max(11, summarizer.fontSize - 1)))
                        .lineSpacing(summarizer.fontSize * 0.25)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
                }
                // While listening, the lines just added stand out and the rest steps back.
                SummaryText(markdown: summary.text, fontSize: summarizer.fontSize, family: model.fontFamily,
                            freshFrom: model.isLive(transcript) && model.isListening ? summary.freshLine : nil)
            }
        } else if !summarizer.isConfigured {
            setupHint(tr("Pick a model for the summary in Settings › Assistant."))
        } else if !summarizer.enabled {
            Text(tr("The summary is off. Turn it on with the switch above."))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text(tr("Notes appear here a few sentences in, and keep growing as the conversation goes on."))
                .font(.callout)
                .foregroundStyle(.secondary)
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
        } else if summarizer.mode == .lecture {
            Text(tr("Not answering in Lecture mode"))
        } else if summarizer.isConfigured {
            Text(answerer.knowledgeCharacters > 0 ? tr("Using your knowledge base") : tr("No knowledge base; the model answers on its own"))
        } else {
            Text(tr("No model set"))
        }
    }

    /// Without Me / Them, nothing tells the interviewer's questions from the reader's own for certain.
    @ViewBuilder private var channelHint: some View {
        if answerer.enabled, summarizer.mode == .interview, !model.splitsBySource {
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
        if !transcript.answers.isEmpty {
            // Newest first and at full strength; earlier ones step back.
            let newest = transcript.answers.last?.id
            VStack(alignment: .leading, spacing: 16) {
                ForEach(transcript.answers.reversed()) { item in
                    AnswerCard(item: item, fontSize: summarizer.fontSize, family: model.fontFamily) {
                        copy(item.answer, notice: tr("Copied answer"))
                    }
                    .opacity(item.id == newest ? 1 : 0.7)
                    if item.id != transcript.answers.first?.id { Divider() }
                }
            }
        } else if !summarizer.isConfigured {
            setupHint(tr("Pick a model for the answers in Settings › Assistant."))
        } else if !answerer.enabled {
            Text(tr("Answers are off. Turn them on with the switch above."))
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text(tr("When someone asks a question, a short answer and hints appear here."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
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

/// One question and its answer.
private struct AnswerCard: View {
    let item: QuestionAnswer
    let fontSize: Double
    let family: String
    let copy: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.55) {
            // For a polish, the question line is what I said; show its start, not its last sentence.
            Text(item.kind == "polish" ? tr("You said") + ": " + item.question : Questions.lastSentence(item.question) ?? item.question)
                .font(LukaFont.font(family, size: max(11, fontSize - 1), weight: .medium))
                .foregroundStyle(.secondary)
                .lineSpacing(fontSize * 0.2)
                .lineLimit(item.kind == "polish" ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .help(item.question)
            SummaryText(markdown: item.answer, fontSize: fontSize, family: family)
            HStack(spacing: 6) {
                if let kind = item.kind {
                    Text(QuestionKind.title(kind))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
                if item.kind != "polish" {
                    Label(item.fromKnowledge ? tr("From your knowledge base") : tr("Model’s own knowledge"),
                          systemImage: item.fromKnowledge ? "books.vertical" : "sparkles")
                    Text(verbatim: "·")
                }
                Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                Spacer()
                Button(action: copy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help(tr("Copy Answer"))
                    .opacity(hovering ? 1 : 0)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
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
        case .lecture: tr("Talks, lectures, podcasts and videos: one structured summary, rewritten as the talk goes on. No answers. Starts with the summary and answers off.")
        case .meeting: tr("Meetings and calls: running notes added in order, with decisions and tasks marked. Only factual or technical questions get a short answer. Starts with the summary on and answers off.")
        case .interview: tr("Interviews: interview questions for your role answered in the first person, and your own answers polished; running notes of each question if you turn the summary on. Starts with answers on, the summary off, and Me / Them.")
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
}
