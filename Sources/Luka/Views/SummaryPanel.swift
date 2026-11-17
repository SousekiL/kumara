import LukaCore
import SwiftUI

/// The column beside the transcript: the live summary, answers to the questions heard, or both.
struct SummaryPanel: View {
    @Environment(AppModel.self) private var model
    let transcript: Transcript
    /// How many answers the user has had in view; the rest count as new on the tab.
    @State private var seenAnswers = 0

    private var summarizer: Summarizer { model.summarizer }
    private var answerer: Answerer { model.answerer }

    private var hasSummary: Bool { summarizer.enabled || transcript.summary != nil }
    private var hasAnswers: Bool { answerer.enabled || !transcript.answers.isEmpty }
    /// With only one of the two in use, the column is just that one, without tabs.
    private var showsTabs: Bool { hasSummary && hasAnswers }
    private var showingAnswers: Bool { showsTabs ? answerer.panelShowsAnswers : hasAnswers }

    var body: some View {
        @Bindable var answerer = model.answerer
        let unseen = max(0, transcript.answers.count - seenAnswers)
        VStack(alignment: .leading, spacing: 0) {
            if showsTabs {
                Picker("", selection: $answerer.panelShowsAnswers) {
                    Text(tr("Summary")).tag(false)
                    Text(unseen > 0 ? tr("Answers") + " · " + String(format: tr("%d new"), unseen) : tr("Answers")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }
            if showingAnswers {
                bar(title: tr("Answers")) { answersStatus } actions: {
                    if answerer.working { ProgressView().controlSize(.small) }
                }
                Divider()
                ScrollView {
                    answers
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .onChange(of: transcript.answers.count, initial: true) { seenAnswers = transcript.answers.count }
            } else {
                bar(title: tr("Live Summary")) { summaryStatus } actions: {
                    if summarizer.working { ProgressView().controlSize(.small) }
                    Button { model.refreshSummary(transcript) } label: { Image(systemName: "arrow.clockwise") }
                        .help(tr("Rewrite from the whole transcript"))
                        .disabled(!summarizer.isConfigured || summarizer.working || transcript.lines.isEmpty)
                    Button { copy(transcript.summary?.text, notice: tr("Copied summary")) } label: { Image(systemName: "doc.on.doc") }
                        .help(tr("Copy Summary"))
                        .disabled(transcript.summary == nil)
                }
                Divider()
                ScrollView {
                    summary
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Answers already there when a session opens aren't news.
        .onAppear { seenAnswers = transcript.answers.count }
        .onChange(of: transcript.id) { seenAnswers = transcript.answers.count }
    }

    /// One row under the tabs: what this is and how fresh, with its actions on the right.
    private func bar(title: String, @ViewBuilder status: () -> some View, @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                // The tab already names the column.
                if !showsTabs { Text(title).font(.headline) }
                status()
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            actions()
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
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
        } else if summarizer.enabled && summarizer.isConfigured {
            Text(tr("Waiting for enough conversation…"))
        } else {
            Text(verbatim: " ")
        }
    }

    @ViewBuilder private var summary: some View {
        if let summary = transcript.summary {
            SummaryText(markdown: summary.text, fontSize: summarizer.fontSize, family: model.fontFamily)
                .id(summary.updatedAt)
                .transition(.opacity)
                .animation(.smooth, value: summary.updatedAt)
        } else if !summarizer.isConfigured || !summarizer.enabled {
            setupHint(tr("Turn on the live summary and pick a model in Settings › Assistant."))
        } else {
            Text(tr("The summary appears here once the conversation gets going."))
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
        } else if answerer.enabled && summarizer.isConfigured {
            Text(answerer.knowledgeCharacters > 0 ? tr("Using your knowledge base") : tr("No knowledge base; the model answers on its own"))
        } else {
            Text(verbatim: " ")
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
        } else if !summarizer.isConfigured || !answerer.enabled {
            setupHint(tr("Turn on answers and pick a model in Settings › Assistant."))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(markdown.split(separator: "\n", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
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
