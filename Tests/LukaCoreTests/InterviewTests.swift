import Foundation
import Testing
@testable import LukaCore

@MainActor
private func tokens(_ list: [(String, Bool, String?)], speaker: String? = nil) -> SonioxResponse {
    SonioxResponse(tokens: list.map { SonioxToken(text: $0.0, isFinal: $0.1, speaker: speaker, language: "en", translationStatus: $0.2) })
}

@MainActor
@Suite struct ChannelTests {
    @Test func channelsKeepTheirOwnLinesAndSpeakers() {
        let t = Transcript()
        t.beginStream(channel: .them)
        t.beginStream(channel: .me)
        // Diarization labels are ignored on a channel: the channel is the speaker.
        t.ingest(tokens([("Tell", true, "original"), (" me", true, "original")], speaker: "1"), channel: .them)
        t.ingest(tokens([("Sure", true, nil)], speaker: "2"), channel: .me)
        t.ingest(tokens([(" about yourself?", true, "original")], speaker: "3"), channel: .them)

        #expect(t.lines.count == 2)
        #expect(t.lines[0].original == "Tell me about yourself?")
        #expect(t.lines[0].speaker == Channel.them.speakerID)
        #expect(t.lines[1].original == "Sure")
        #expect(t.lines[1].speaker == Channel.me.speakerID)
        #expect(t.visibleSpeakers.count == 2)
    }

    @Test func translationsFollowTheirChannel() {
        let t = Transcript()
        t.ingest(tokens([("How are you?", true, "original")]), channel: .them)
        t.ingest(tokens([("Fine", true, nil)]), channel: .me)
        t.ingest(SonioxResponse(tokens: [SonioxToken(text: "你好吗？", isFinal: true, language: "zh", translationStatus: "translation")]), channel: .them)
        #expect(t.lines[0].translation == "你好吗？")
        #expect(t.lines[1].translation.isEmpty)
    }

    @Test func provisionalShowsWhoeverSpokeLast() {
        let t = Transcript()
        t.ingest(tokens([("So what", false, nil)]), channel: .them)
        #expect(t.provisional?.text == "So what")
        t.ingest(tokens([("um", false, nil)]), channel: .me)
        #expect(t.provisional?.text == "um")
        t.ingest(tokens([]), channel: .me)
        #expect(t.provisional?.text == "So what")
    }

    @Test func aChannelReconnectDoesNotCloseTheOtherChannel() {
        let t = Transcript()
        t.ingest(tokens([("Hello", true, nil)]), channel: .them)
        t.beginStream(channel: .me)
        t.ingest(tokens([(" there", true, nil)]), channel: .them)
        #expect(t.lines.count == 1)
        #expect(t.lines[0].original == "Hello there")
    }

    @Test func myVoiceConfigCanSkipTranslation() {
        let base = SessionConfig(mode: .translate, source: "en", target: "zh", languageA: "en", languageB: "zh", context: "")
        let mine = base.forMyVoice(translate: false)
        let payload = mine.payload(apiKey: "k")
        #expect(payload["translation"] == nil)
        #expect(payload["enable_speaker_diarization"] as? Bool == false)
        #expect(!mine.translates)
        let translated = base.forMyVoice(translate: true).payload(apiKey: "k")
        #expect(translated["translation"] != nil)
    }
}

@MainActor
@Suite struct QuestionTests {
    @Test(arguments: [
        "Why do you want to join our team?",
        "Tell me about a time you disagreed with your manager.",
        "Okay. Walk me through your resume",
        "So what made you move from tech into insurance",
        "Could you explain how you would price a new product",
        "你为什么想加入我们公司？",
        "你有什么问题吗",
        "Thanks. Why actuarial science?",
    ])
    func recognizesQuestions(_ text: String) {
        #expect(Questions.isQuestion(text))
    }

    @Test(arguments: [
        "That sounds great.",
        "Thanks for joining us today.",
        "I see",
        "We have a team of twelve actuaries.",
        "Why insurance? Okay, that makes sense.",
    ])
    func ignoresStatements(_ text: String) {
        #expect(!Questions.isQuestion(text))
    }

    @Test func pinsOnlyTheirLatestQuestion() {
        let t = Transcript()
        t.ingest(tokens([("What is your notice period?", true, nil), ("<end>", true, nil)]), channel: .them)
        t.ingest(tokens([("Two weeks. Does that work?", true, nil)]), channel: .me)
        t.ingest(tokens([("Yes, that works fine.", true, nil)]), channel: .them)
        #expect(t.pinnedQuestion(channelsOnly: true)?.original == "What is your notice period?")
    }

    @Test func oldQuestionsUnpin() {
        let t = Transcript()
        t.ingest(tokens([("What is your notice period?", true, nil)]), at: .now.addingTimeInterval(-1_000), channel: .them)
        #expect(t.pinnedQuestion(channelsOnly: true) == nil)
    }
}

@Suite struct UsageTests {
    @Test func estimatesCostByRate() {
        var u = UsageTotals()
        u.add(ms: 3_600_000, translated: true)
        u.add(ms: 1_800_000, translated: false)
        #expect(abs(u.estimatedCost - 0.24) < 0.0001)
        #expect(u.minutes == 90)
        #expect(u.summary == "90 min · ≈ $0.24")
    }

    @Test func monthKey() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        #expect(UsageTotals.monthKey(Date(timeIntervalSince1970: 1_794_960_000), calendar: cal) == "2026-11")
    }
}
