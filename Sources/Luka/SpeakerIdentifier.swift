import Foundation
import LukaCore
import Observation

/// Works out who each speaker is from what was said, with the deep model. Nothing changes until
/// the reader applies the proposals, and what they apply can be undone.
@MainActor
@Observable
final class SpeakerIdentifier {
    struct Result {
        let session: UUID
        var proposals: [SpeakerProposal]
        var note: String
    }

    /// Propose names on opening the speakers list of a session that has none yet.
    var suggestsAutomatically: Bool { didSet { UserDefaults.standard.set(suggestsAutomatically, forKey: "speakers.autoSuggest") } }
    private(set) var working = false
    /// The session being read.
    private(set) var workingOn: UUID?
    private(set) var error: String?
    private(set) var result: Result?
    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        suggestsAutomatically = UserDefaults.standard.object(forKey: "speakers.autoSuggest") as? Bool ?? true
    }

    /// On opening the speakers list: one pass per session, again only once it has grown by half.
    func suggestIfNeeded(_ t: Transcript, listening: Bool, service: AssistantService) {
        guard suggestsAutomatically, !listening, t.lines.count >= 30, t.speakerSuggestions.isEmpty else { return }
        if let seen = t.speakerSuggestedLines, t.lines.count < seen + max(30, seen / 2) { return }
        let notes = t.speakerNotes
        identify(t, hints: SpeakerHints(count: notes.count, names: SpeakerHints.parseNames(notes.names), notes: notes.notes,
                                        reader: service.names), service: service)
    }

    func identify(_ t: Transcript, hints: SpeakerHints, service: AssistantService) {
        guard service.isAskConfigured, !working else { return }
        let sheet = t.speakerSheet()
        guard sheet.tags.count >= 1, !sheet.text.isEmpty else { return }
        let session = t.id
        working = true
        workingOn = session
        error = nil
        result = nil
        task = Task {
            defer {
                working = false
                workingOn = nil
            }
            do {
                let reply = try await service.deepStream(system: SpeakerPrompt.system, user: SpeakerPrompt.user(sheet: sheet.text, hints: hints))
                guard !Task.isCancelled else { return }
                guard let parsed = SpeakerPrompt.parse(reply, tags: sheet.tags) else {
                    error = tr("The model’s reply couldn’t be read. Try again.")
                    return
                }
                result = Result(session: session, proposals: parsed.proposals, note: parsed.note)
                // Kept with the session, so the speakers list can offer them later.
                t.speakerSuggestions = parsed.proposals
                t.speakerSuggestedLines = t.lines.count
                onResult(t)
            } catch let e where Task.isCancelled || e is CancellationError || (e as? URLError)?.code == .cancelled {
            } catch let e {
                error = e.localizedDescription
                AudioLog.write("speaker identification failed: \(e.localizedDescription)")
            }
        }
    }

    /// Called with the session once proposals are stored in it, to save it.
    @ObservationIgnored var onResult: (Transcript) -> Void = { _ in }

    /// The sheet closed: its result is no longer shown, but a pass under way carries on.
    func clear() {
        result = nil
        error = nil
    }
}
