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

    private(set) var working = false
    private(set) var error: String?
    private(set) var result: Result?
    @ObservationIgnored private var task: Task<Void, Never>?

    func identify(_ t: Transcript, hints: SpeakerHints, service: AssistantService) {
        guard service.isAskConfigured, !working else { return }
        let sheet = t.speakerSheet()
        guard sheet.tags.count >= 1, !sheet.text.isEmpty else { return }
        let session = t.id
        working = true
        error = nil
        result = nil
        task = Task {
            defer { working = false }
            do {
                let reply = try await service.deepStream(system: SpeakerPrompt.system, user: SpeakerPrompt.user(sheet: sheet.text, hints: hints))
                guard !Task.isCancelled else { return }
                guard let parsed = SpeakerPrompt.parse(reply, tags: sheet.tags) else {
                    error = tr("The model’s reply couldn’t be read. Try again.")
                    return
                }
                result = Result(session: session, proposals: parsed.proposals, note: parsed.note)
            } catch let e where Task.isCancelled || e is CancellationError || (e as? URLError)?.code == .cancelled {
            } catch let e {
                error = e.localizedDescription
                AudioLog.write("speaker identification failed: \(e.localizedDescription)")
            }
        }
    }

    func clear() {
        task?.cancel()
        result = nil
        error = nil
    }
}
