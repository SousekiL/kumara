import LukaCore
import SwiftUI

/// Who is who: the reader says what they know, the deep model proposes names and merges,
/// and the reader picks which to apply.
struct SpeakerIdentifySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let transcript: Transcript

    @AppStorage("speakers.hint.names") private var names = ""
    @AppStorage("speakers.hint.notes") private var notes = ""
    @State private var count = 0
    @State private var accepted: Set<SpeakerID> = []

    private var identifier: SpeakerIdentifier { model.speakerIdentifier }
    private var result: SpeakerIdentifier.Result? {
        identifier.result.flatMap { $0.session == transcript.id ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Who’s speaking")).font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 20).padding(.bottom, 4)
            Text(tr("The analysis model reads the session and works out who each speaker is, and which speakers are the same person. Tell it what you know; everything is optional."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20).padding(.bottom, 12)

            Form {
                Section {
                    Stepper(value: $count, in: 0...30) {
                        LabeledContent(tr("People in the session, you included")) {
                            Text(count == 0 ? tr("Not sure") : "\(count)").foregroundStyle(count == 0 ? .secondary : .primary)
                        }
                    }
                    TextField(tr("Names"), text: $names, prompt: Text(verbatim: "Irene, Roy, Preethi"), axis: .vertical)
                        .lineLimit(1...3)
                    TextField(tr("About them"), text: $notes,
                              prompt: Text(tr("Optional, e.g. “Irene interviews and asks most questions; Roy is the engineer.”")), axis: .vertical)
                        .lineLimit(2...5)
                }
                if let result {
                    Section {
                        ForEach(result.proposals) { p in
                            ProposalRow(proposal: p, transcript: transcript, on: Binding(
                                get: { accepted.contains(p.id) },
                                set: { if $0 { accepted.insert(p.id) } else { accepted.remove(p.id) } }))
                        }
                    } header: {
                        Text(tr("Proposed"))
                    } footer: {
                        Text((result.note.isEmpty ? "" : result.note + "\n")
                             + tr("Speakers given the same name become one. Low-confidence guesses start unticked. “Same person” entries merge without naming anyone."))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            if let error = identifier.error {
                Text(error).font(.callout).foregroundStyle(.red).lineLimit(3)
                    .padding(.horizontal, 20).padding(.bottom, 6)
            }
            HStack {
                if transcript.speakerBackup != nil {
                    Button(tr("Undo Names and Merges")) { transcript.undoSpeakerNames() }
                        .help(tr("Put speakers back as they were before the first proposal was applied"))
                }
                Menu {
                    Button(tr("Reset Every Speaker"), role: .destructive) { transcript.resetSpeakers() }
                        .disabled(!transcript.hasSpeakerEdits)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden).fixedSize()
                .help(tr("Reset Every Speaker: no names, nothing merged, as first transcribed"))
                Spacer()
                if identifier.working {
                    ProgressView().controlSize(.small)
                    Text(tr("Reading the session…")).foregroundStyle(.secondary)
                }
                Button(tr("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(result == nil ? tr("Identify") : tr("Try Again")) { run() }
                    .disabled(identifier.working || !model.assistant.isAskConfigured)
                if result != nil {
                    Button(tr("Apply")) { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(accepted.isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 520, height: result == nil ? 380 : 620)
        .onChange(of: result?.proposals) { _, proposals in
            // Anything better than a guess starts accepted.
            accepted = Set((proposals ?? []).filter { $0.confidence > .low }.map(\.id))
        }
        .onDisappear { identifier.clear() }
    }

    private func run() {
        let hints = SpeakerHints(count: count, names: SpeakerHints.parseNames(names), notes: notes, reader: model.assistant.names)
        identifier.identify(transcript, hints: hints, service: model.assistant)
    }

    private func apply() {
        guard let result else { return }
        let changed = withAnimation(.smooth) { transcript.apply(result.proposals.filter { accepted.contains($0.id) }) }
        model.store.save(transcript)
        model.show(String(format: tr("%d speaker change(s) applied"), changed))
        dismiss()
    }
}

private struct ProposalRow: View {
    @Environment(AppModel.self) private var model
    let proposal: SpeakerProposal
    let transcript: Transcript
    @Binding var on: Bool

    var body: some View {
        Toggle(isOn: $on) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(model.speakerColor(proposal.id, in: transcript)).frame(width: 8, height: 8)
                Text(model.speakerName(proposal.id, in: transcript)).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                Text(proposal.isPlaceholder ? tr("Same person") + " " + String(proposal.person.dropFirst()) : proposal.person)
                    .fontWeight(.medium)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.16), in: .capsule)
                    .foregroundStyle(color)
                Spacer(minLength: 0)
            }
            if !proposal.why.isEmpty {
                Text(proposal.why).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var label: String {
        switch proposal.confidence {
        case .high: tr("Sure")
        case .medium: tr("Likely")
        case .low: tr("Guess")
        }
    }

    private var color: Color {
        switch proposal.confidence {
        case .high: .green
        case .medium: .orange
        case .low: .secondary
        }
    }
}
