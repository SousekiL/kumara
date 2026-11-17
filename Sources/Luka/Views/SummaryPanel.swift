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
                    Text(unseen > 0 ? tr("Answers") + " · " + String(format: tr("%d new"), unseen) : tr("Answers")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 4)
                // The kind of conversation: how the summary is kept, how readily questions are answered.
                Picker("", selection: $summarizer.mode) {
                    ForEach(AssistantMode.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help(summarizer.mode.explanation)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            if answerer.panelShowsAnswers {
                bar { answersStatus } actions: {
                    if answerer.working { ProgressView().controlSize(.small) }
                    Toggle("", isOn: $answerer.enabled)
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .help(tr("Answer questions as they’re asked"))
                }
                Divider()
                ScrollView {
                    answers
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .onChange(of: transcript.answers.count, initial: true) { seenAnswers = transcript.answers.count }
            } else {
                bar { summaryStatus } actions: {
                    if summarizer.working { ProgressView().controlSize(.small) }
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
                        .padding(14)
                }
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
                    withAnimation(.smooth(duration: 0.3)) { notesPosition.scrollTo(edge: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Answers already there when a session opens aren't news.
        .onAppear { seenAnswers = transcript.answers.count }
        .onChange(of: transcript.id) { seenAnswers = transcript.answers.count }
    }

    /// One row under the tabs: what this is and how fresh, with its actions on the right.
    private func bar(@ViewBuilder status: () -> some View, @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 10) {
            status()
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            actions()
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 30)
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
            Text(error).foregroundStyle(.red).lineLimit(2).help(error)
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
            VStack(alignment: .leading, spacing: 10) {
                if let context = summary.context, !context.isEmpty {
                    Text(context)
                        .font(LukaFont.font(model.fontFamily, size: max(10, summarizer.fontSize - 1)))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                }
                // While listening, the lines just added stand out and the rest steps back.
                SummaryText(markdown: summary.text, fontSize: summarizer.fontSize, family: model.fontFamily,
                            freshFrom: model.isLive(transcript) && model.isListening ? summary.freshLine : nil)
                    .animation(.smooth, value: summary.text)
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
            Text(error).foregroundStyle(.red).lineLimit(2).help(error)
        } else if answerer.working {
            Text(tr("Answering…"))
        } else if !answerer.enabled {
            Text(tr("Off"))
        } else if summarizer.isConfigured {
            Text(answerer.knowledgeCharacters > 0 ? tr("Using your knowledge base") : tr("No knowledge base; the model answers on its own"))
        } else {
            Text(tr("No model set"))
        }
    }

    @ViewBuilder private var answers: some View {
        if !transcript.answers.isEmpty {
            // Newest first and at full strength; earlier ones step back.
            let newest = transcript.answers.last?.id
            VStack(alignment: .leading, spacing: 14) {
                ForEach(transcript.answers.reversed()) { item in
                    AnswerCard(item: item, fontSize: summarizer.fontSize, family: model.fontFamily) {
                        copy(item.answer, notice: tr("Copied answer"))
                    }
                    .opacity(item.id == newest ? 1 : 0.6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    if item.id != transcript.answers.first?.id { Divider() }
                }
            }
            .animation(.smooth, value: transcript.answers.count)
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
struct SummaryText: View {
    let markdown: String
    let fontSize: Double
    let family: String
    /// The first line of the latest addition; earlier lines are dimmed. Nil shows everything alike.
    var freshFrom: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(markdown.split(separator: "\n", omittingEmptySubsequences: true).enumerated()), id: \.offset) { index, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                let old = freshFrom.map { index < $0 } ?? false
                Group {
                if line.hasPrefix("#") {
                    Text(inline(String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)))
                        .font(LukaFont.font(family, size: fontSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•").foregroundStyle(.secondary)
                        Text(inline(String(line.dropFirst(2))))
                    }
                    .font(LukaFont.font(family, size: fontSize))
                } else {
                    Text(inline(line)).font(LukaFont.font(family, size: fontSize))
                }
                }
                .opacity(old ? 0.62 : 1)
                .transition(.opacity)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(Questions.lastSentence(item.question) ?? item.question)
                .font(LukaFont.font(family, size: max(10, fontSize - 1), weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .help(item.question)
            SummaryText(markdown: item.answer, fontSize: fontSize, family: family)
            HStack(spacing: 6) {
                Label(item.fromKnowledge ? tr("From your knowledge base") : tr("Model’s own knowledge"),
                      systemImage: item.fromKnowledge ? "books.vertical" : "sparkles")
                Text(verbatim: "·")
                Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                Spacer()
                Button(action: copy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help(tr("Copy Answer"))
                    .opacity(hovering ? 1 : 0)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
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
        case .lecture: tr("Talks, lectures, podcasts and videos: one structured summary, rewritten as the talk goes on. Only questions left open are answered.")
        case .meeting: tr("Meetings and calls: running notes added in order, with decisions and tasks marked. Questions asked by others are answered.")
        case .interview: tr("Interviews: running notes of each question and what the answer covered. Every question and prompt from the other side is answered, in the first person.")
        }
    }
}
