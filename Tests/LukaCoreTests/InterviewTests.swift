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

@MainActor
@Suite struct SummaryTests {
    @Test func endpointURLs() {
        #expect(SummaryEndpoint(provider: .openAI, baseURL: "", model: "m").url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(SummaryEndpoint(provider: .openAI, baseURL: "https://api.deepseek.com/v1/", model: "m").url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(SummaryEndpoint(provider: .anthropic, baseURL: "", model: "m").url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(SummaryEndpoint(provider: .anthropic, baseURL: "https://proxy.example/v1", model: "m").url?.absoluteString == "https://proxy.example/v1/messages")
    }

    @Test func buildsProviderRequests() throws {
        let openAI = try #require(SummaryEndpoint(provider: .openAI, baseURL: "", model: "gpt").request(apiKey: " k ", system: "s", user: "u"))
        #expect(openAI.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let body = try #require(JSONSerialization.jsonObject(with: openAI.httpBody!) as? [String: Any])
        #expect((body["messages"] as? [[String: String]])?.first?["role"] == "system")

        let claude = try #require(SummaryEndpoint(provider: .anthropic, baseURL: "", model: "claude").request(apiKey: "k", system: "s", user: "u"))
        #expect(claude.value(forHTTPHeaderField: "x-api-key") == "k")
        let cbody = try #require(JSONSerialization.jsonObject(with: claude.httpBody!) as? [String: Any])
        #expect(cbody["system"] as? String == "s")
        #expect(cbody["max_tokens"] as? Int == 1_500)
    }

    @Test func parsesRepliesAndErrors() throws {
        let openAI = SummaryEndpoint(provider: .openAI, baseURL: "", model: "m")
        let reply = #"{"choices":[{"message":{"role":"assistant","content":"```markdown\n## Key points\n- A\n```"}}]}"#
        #expect(try openAI.parse(Data(reply.utf8)) == "## Key points\n- A")
        let claude = SummaryEndpoint(provider: .anthropic, baseURL: "", model: "m")
        #expect(try claude.parse(Data(#"{"content":[{"type":"text","text":"- B"}]}"#.utf8)) == "- B")
        #expect(throws: SummaryEndpoint.ResponseError.api("bad key")) {
            try claude.parse(Data(#"{"type":"error","error":{"type":"authentication_error","message":"bad key"}}"#.utf8))
        }
    }

    @Test func updatePolicy() {
        #expect(!SummaryPrompt.shouldUpdate(newCharacters: 0, sinceUpdate: 500, sinceLastSpeech: 500))
        #expect(SummaryPrompt.shouldUpdate(newCharacters: 600, sinceUpdate: 1, sinceLastSpeech: 0))
        #expect(SummaryPrompt.shouldUpdate(newCharacters: 120, sinceUpdate: 20, sinceLastSpeech: 8))
        #expect(!SummaryPrompt.shouldUpdate(newCharacters: 120, sinceUpdate: 20, sinceLastSpeech: 2))
        #expect(SummaryPrompt.shouldUpdate(newCharacters: 10, sinceUpdate: 95, sinceLastSpeech: 0))
    }

    @Test func summaryTextSkipsCoveredAndOpenLines() {
        let t = Transcript()
        t.ingest(tokens([("Hello there.", true, nil), ("<end>", true, nil)]), channel: .them)
        t.ingest(tokens([("Hi.", true, nil), ("<end>", true, nil)]), channel: .me)
        t.ingest(tokens([("Still talking", true, nil)]), channel: .them)
        let name: (SpeakerID) -> String = { Channel($0) == .me ? "Me" : "Them" }
        let all = t.summaryText(after: nil, closedOnly: true, limit: 1_000, name: name)
        #expect(all.text == "Them: Hello there.\nMe: Hi.")
        #expect(all.lastLineID == t.lines[1].id)
        let rest = t.summaryText(after: t.lines[0].id, closedOnly: false, limit: 1_000, name: name)
        #expect(rest.text == "Me: Hi.\nThem: Still talking")
        let cut = t.summaryText(after: nil, closedOnly: false, limit: 20, name: name)
        #expect(cut.truncated && cut.text == "Them: Still talking")
    }

    @Test func summarySurvivesSaveAndExport() throws {
        let t = Transcript()
        t.ingest(tokens([("Hello.", true, nil)]), channel: .them)
        t.summary = LiveSummary(text: "## Key points\n- Greeting", updatedAt: .now, coveredLineID: 0)
        let data = try JSONEncoder().encode(t.snapshot)
        let back = Transcript(snapshot: try JSONDecoder().decode(TranscriptSnapshot.self, from: data))
        #expect(back.summary?.text == "## Key points\n- Greeting")
        #expect(back.markdown(title: "T", name: { _ in "X" }, includeOriginal: false).contains("## Summary\n\n### Key points\n- Greeting"))
    }
}

@Suite struct AccountTests {
    @Test func parsesBalance() throws {
        let json = #"{"available_balance_usd":"7.4200000000","free_balance_usd":"0.0000","used_balance_usd":"2.58","invoice_billing_enabled":false,"balance_exhausted":false,"autopay_enabled":false}"#
        let b = try SonioxAccount.parseBalance(Data(json.utf8))
        #expect(b.availableUSD == 7.42 && b.usedUSD == 2.58 && !b.exhausted)
    }

    @Test func parsesMonthCostAndErrors() throws {
        let json = #"{"total":{"model":null,"days":["2026-11-01"],"total_cost_usd":"0.2567250000"},"models":[]}"#
        #expect(try SonioxAccount.parseMonthCost(Data(json.utf8)) == 0.256725)
        let err = #"{"status_code":403,"error_type":"permission_denied","message":"Organization API key required"}"#
        #expect(throws: SonioxAccount.Failure(message: "Organization API key required")) { try SonioxAccount.parseBalance(Data(err.utf8)) }
    }

    @Test func monthWindowIsUTCMonthToTomorrow() {
        let now = Date(timeIntervalSince1970: 1_794_916_800) // 2026-11-17 12:00 UTC
        let r = SonioxAccount.monthCostRequest(apiKey: "k", apiHost: "api.soniox.com", now: now)
        let q = r.url!.query!
        #expect(q.contains("start_time=2026-11-01T00:00:00Z"))
        #expect(q.contains("end_time=2026-11-18T00:00:00Z"))
    }
}
