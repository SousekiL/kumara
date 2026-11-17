import LukaCore
import SwiftUI

/// The column beside the transcript: the live summary, or answers to the questions heard.
struct SummaryPanel: View {
    @Environment(AppModel.self) private var model
    let transcript: Transcript

    private var summarizer: Summarizer { model.summarizer }
    private var answerer: Answerer { model.answerer }

    var body: some View {
        @Bindable var answerer = model.answerer
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $answerer.panelShowsAnswers) {
                Text(tr("Summary")).tag(false)
                Text(transcript.answers.isEmpty ? tr("Answers") : tr("Answers") + " (\(transcript.answers.count))").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 10)
            if answerer.panelShowsAnswers {
                answersHeader
                Divider()
                ScrollView {
                    answers
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                header
                Divider()
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Summary

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Live Summary")).font(.headline)
                status
            }
            Spacer()
            if summarizer.working {
                ProgressView().controlSize(.small)
            }
            Button {
                model.refreshSummary(transcript)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(tr("Rewrite from the whole transcript"))
            .disabled(!summarizer.isConfigured || summarizer.working || transcript.lines.isEmpty)
            Button {
                guard let text = transcript.summary?.text else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                model.show(tr("Copied summary"))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(tr("Copy Summary"))
            .disabled(transcript.summary == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var status: some View {
        Group {
            if let error = summarizer.lastError {
                Text(error).foregroundStyle(.red).lineLimit(2)
            } else if let summary = transcript.summary {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Text(String(format: tr("Updated %@"), Self.ago(summary.updatedAt, now: context.date)))
                }
            } else if summarizer.enabled && summarizer.isConfigured {
                Text(tr("Waiting for enough conversation…"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var content: some View {
        if !summarizer.isConfigured || !summarizer.enabled {
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("Turn on the live summary and pick a model in Settings › Assistant."))
                    .foregroundStyle(.secondary)
                Button(tr("Open Settings…")) { model.openSettings() }
            }
        } else if let summary = transcript.summary {
            SummaryText(markdown: summary.text, fontSize: summarizer.fontSize, family: model.fontFamily)
                .id(summary.updatedAt)
                .transition(.opacity)
                .animation(.smooth, value: summary.updatedAt)
        } else {
            Text(tr("The summary appears here once the conversation gets going."))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Answers

    private var answersHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Answers")).font(.headline)
                Group {
                    if let error = answerer.lastError {
                        Text(error).foregroundStyle(.red).lineLimit(2)
                    } else if answerer.enabled && summarizer.isConfigured {
                        Text(answerer.knowledgeCharacters > 0 ? tr("Using your knowledge base") : tr("No knowledge base; the model answers on its own"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if answerer.working {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var answers: some View {
        if !summarizer.isConfigured || !answerer.enabled {
            VStack(alignment: .leading, spacing: 10) {
                Text(tr("Turn on answers and pick a model in Settings › Assistant."))
                    .foregroundStyle(.secondary)
                Button(tr("Open Settings…")) { model.openSettings() }
            }
        } else if transcript.answers.isEmpty {
            Text(tr("When someone asks a question, a short answer and hints appear here."))
                .foregroundStyle(.secondary)
        } else {
            // Newest first: the question being answered now is always at the top.
            VStack(alignment: .leading, spacing: 18) {
                ForEach(transcript.answers.reversed()) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.question)
                            .font(LukaFont.font(model.fontFamily, size: max(10, summarizer.fontSize - 2)))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        SummaryText(markdown: item.answer, fontSize: summarizer.fontSize, family: model.fontFamily)
                        Label(item.fromKnowledge ? tr("From your knowledge base") : tr("Model’s own knowledge"),
                              systemImage: item.fromKnowledge ? "books.vertical" : "sparkles")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.smooth, value: transcript.answers.count)
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
