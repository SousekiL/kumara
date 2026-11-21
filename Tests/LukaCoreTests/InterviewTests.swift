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
        // Me is always one speaker; Them keeps Soniox's labels apart, still on the Them side.
        t.ingest(tokens([("Tell", true, "original"), (" me", true, "original")], speaker: "1"), channel: .them)
        t.ingest(tokens([("Sure", true, nil)], speaker: "2"), channel: .me)
        t.ingest(tokens([(" about yourself?", true, "original")], speaker: "1"), channel: .them)
        t.ingest(tokens([("And your team?", true, "original")], speaker: "2"), channel: .them)

        #expect(t.lines.count == 3)
        #expect(t.lines[0].original == "Tell me about yourself?")
        #expect(Channel(t.lines[0].speaker) == .them)
        #expect(t.lines[1].speaker == Channel.me.speakerID)
        #expect(Channel(t.lines[2].speaker) == .them && t.lines[2].speaker != t.lines[0].speaker)
        #expect(t.visibleSpeakers.count == 3)
        let them = t.visibleSpeakers.filter { Channel($0.id) == .them }.map(\.ordinal)
        #expect(them == [1, 2])
    }

    @Test func unlabeledThemTranslationGoesToTheLastThemSpeaker() {
        let t = Transcript()
        t.beginStream(channel: .them)
        t.ingest(tokens([("How are you?", true, "original"), ("<end>", true, nil)], speaker: "2"), channel: .them)
        t.ingest(tokens([("Fine, thanks for asking today.", true, "original")]), channel: .me)
        t.ingest(SonioxResponse(tokens: [SonioxToken(text: "你好吗？", isFinal: true, language: "zh", translationStatus: "translation")]), channel: .them)
        #expect(t.lines[0].translation == "你好吗？" && t.lines[1].translation.isEmpty)
        #expect(t.visibleSpeakers.count == 2)

        let back = Transcript(snapshot: t.snapshot)
        back.beginStream(channel: .them)
        back.ingest(tokens([("New voice.", true, nil)], speaker: "2"), channel: .them)
        #expect(back.lines.last?.speaker != back.lines[0].speaker)
    }

    @Test func aNewThemStreamMeansNewPeople() {
        let t = Transcript()
        t.beginStream(channel: .them)
        t.ingest(tokens([("Hi.", true, nil), ("<end>", true, nil)], speaker: "1"), channel: .them)
        t.beginStream(channel: .them)
        t.ingest(tokens([("Hello.", true, nil), ("<end>", true, nil)], speaker: "1"), channel: .them)
        #expect(t.lines[0].speaker != t.lines[1].speaker)
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
        // The system prompt is marked for caching; so is text shared from one request to the next.
        let system = try #require((cbody["system"] as? [[String: Any]])?.first)
        #expect(system["text"] as? String == "s" && system["cache_control"] != nil)
        #expect(((cbody["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])?.count == 1)
        let kb = try #require(SummaryEndpoint(provider: .anthropic, baseURL: "", model: "claude").request(apiKey: "k", system: "s", user: "u", shared: "kb"))
        let content = try #require(((try JSONSerialization.jsonObject(with: kb.httpBody!) as? [String: Any])?["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        #expect(content.map { $0["text"] as? String } == ["kb", "u"])
        #expect(content[0]["cache_control"] != nil && content[1]["cache_control"] == nil)
        let plain = try #require(SummaryEndpoint(provider: .openAI, baseURL: "", model: "gpt").request(apiKey: "k", system: "s", user: "u", shared: "kb"))
        let pbody = try #require(JSONSerialization.jsonObject(with: plain.httpBody!) as? [String: Any])
        #expect((pbody["messages"] as? [[String: String]])?.last?["content"] == "kbu")
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
        #expect(!SummaryPrompt.shouldUpdate(newWeight: 10, sinceUpdate: 500, sinceLastSpeech: 500))
        #expect(SummaryPrompt.shouldUpdate(newWeight: 400, sinceUpdate: 1, sinceLastSpeech: 0))
        #expect(SummaryPrompt.shouldUpdate(newWeight: 120, sinceUpdate: 5, sinceLastSpeech: 4))
        #expect(!SummaryPrompt.shouldUpdate(newWeight: 120, sinceUpdate: 5, sinceLastSpeech: 1))
        #expect(SummaryPrompt.shouldUpdate(newWeight: 50, sinceUpdate: 35, sinceLastSpeech: 0))
        #expect(SummaryPrompt.weight("abc") == 3 && SummaryPrompt.weight("你好") == 4)
    }

    @Test func repliesAreAppendedAndEarlierNotesStay() {
        let first = SummaryPrompt.merge(nil, reply: "CONTEXT: Likely a budget meeting.\n## Budget\n- Q3 spend was $2M.", coveredLineID: 3)
        #expect(first.context == "Likely a budget meeting.")
        #expect(first.text == "## Budget\n- Q3 spend was $2M.")
        #expect(first.freshLine == 0)

        let second = SummaryPrompt.merge(first, reply: "- **Decision:** freeze hiring.", coveredLineID: 6)
        #expect(second.text == "## Budget\n- Q3 spend was $2M.\n- **Decision:** freeze hiring.")
        #expect(second.freshLine == 2 && second.context == first.context && second.coveredLineID == 6)

        // A repeated heading continues the topic; a new one starts a section.
        let third = SummaryPrompt.merge(second, reply: "## budget\n- Travel is cut.", coveredLineID: 7)
        #expect(third.text.hasSuffix("freeze hiring.\n- Travel is cut."))
        let fourth = SummaryPrompt.merge(third, reply: "```\n## Hiring\n- Two offers are out.\n```", coveredLineID: 9)
        #expect(fourth.text.hasSuffix("- Travel is cut.\n\n## Hiring\n- Two offers are out."))
        #expect(fourth.text.hasPrefix(third.text))
    }

    @Test func nothingToAddOnlyMovesTheMarker() {
        let base = LiveSummary(text: "## A\n- x", updatedAt: Date(timeIntervalSince1970: 5), coveredLineID: 1, context: "c", freshLine: 0)
        let same = SummaryPrompt.merge(base, reply: "NONE", coveredLineID: 4)
        #expect(same.text == base.text && same.updatedAt == base.updatedAt && same.coveredLineID == 4)
        let kept = SummaryPrompt.merge(base, reply: "CONTEXT: newer", coveredLineID: 5, replacing: true)
        #expect(kept.text == base.text && kept.context == "newer")
        let replaced = SummaryPrompt.merge(base, reply: "CONTEXT: new\n## B\n- y", coveredLineID: 8, replacing: true)
        #expect(replaced.text == "## B\n- y" && replaced.context == "new" && replaced.freshLine == nil)
    }

    @Test func appendPromptCarriesOnlyTheNotesTail() {
        let long = (["## Old topic"] + (0..<60).map { "- Earlier point number \($0) with some words." } + ["## Current", "- Latest point."]).joined(separator: "\n")
        let prompt = SummaryPrompt.append(current: LiveSummary(text: long, updatedAt: .now, coveredLineID: 1), newTranscript: "A: hi")
        #expect(prompt.contains("## Current\n- Latest point."))
        #expect(!prompt.contains("number 3 "))
        #expect(SummaryPrompt.append(current: nil, newTranscript: "A: hi").contains("The notes are empty"))
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

@Suite struct PromptTests {
    @Test func promptCarriesLimitsLanguageAndExtras() {
        let p = SummaryPrompt.system(language: "Simplified Chinese", detail: .concise, extra: " List numbers. ")
        #expect(p.contains("Write in Simplified Chinese"))
        #expect(p.contains("Usually 1 or 2 bullets per update"))
        #expect(p.hasSuffix("List numbers."))
        #expect(!SummaryPrompt.system(language: "English").contains("reader's own instructions"))
    }

    @Test func untranslatedTwoWayVoiceKeepsBothHints() {
        let base = SessionConfig(mode: .twoWay, source: nil, target: "zh", languageA: "en", languageB: "zh", context: "")
        let payload = base.forMyVoice(translate: false).payload(apiKey: "k")
        #expect(payload["language_hints"] as? [String] == ["en", "zh"])
        #expect(payload["translation"] == nil)
    }
}

@MainActor
@Suite struct AnswerTests {
    @Test func parsesSourceAndSkip() {
        let a = AnswerPrompt.parse("SOURCE: knowledge\nLoss ratio is 62%.\n- From the 2025 report")
        #expect(a?.fromKnowledge == true)
        #expect(a?.text == "Loss ratio is 62%.\n- From the 2025 report")
        #expect(AnswerPrompt.parse("SOURCE: model\nIt depends.")?.fromKnowledge == false)
        #expect(AnswerPrompt.parse("SKIP") == nil)
        #expect(AnswerPrompt.parse("SOURCE: model\nSKIP.") == nil)
        #expect(AnswerPrompt.parse("Plain answer")?.text == "Plain answer")
    }

    @Test func smallKnowledgeBaseGoesInWhole() {
        let kb = KnowledgeBase(documents: [("resume.md", "Worked at TikTok on causal inference.\nPassed exam ASTAM.")])
        #expect(kb.excerpts(for: "anything") == "[resume.md]\nWorked at TikTok on causal inference.\nPassed exam ASTAM.")
        #expect(KnowledgeBase().excerpts(for: "anything").isEmpty)
    }

    @Test func largeKnowledgeBasePicksMatchingChunks() {
        let filler = (0..<40).map { "Paragraph \($0) about unrelated weather and gardening topics, long enough to fill space in the base." }.joined(separator: "\n")
        let kb = KnowledgeBase(documents: [
            ("notes.txt", filler),
            ("pricing.txt", "Our reserving model uses the chain ladder method with a 62% loss ratio.\n准备金评估采用链梯法。"),
        ], chunkSize: 300)
        let english = kb.excerpts(for: "What loss ratio does the reserving model assume?", limit: 600)
        #expect(english.contains("[pricing.txt]") && english.contains("62%"))
        #expect(english.count <= 700)
        let chinese = kb.excerpts(for: "准备金怎么评估？", limit: 600)
        #expect(chinese.contains("链梯法"))
        #expect(kb.excerpts(for: "zzzz qqqq", limit: 600).isEmpty)
    }

    @Test func waitingQuestionIsNewestUnhandledFromThem() {
        let t = Transcript()
        t.ingest(tokens([("What is IBNR?", true, nil), ("<end>", true, nil)]), channel: .them)
        t.ingest(tokens([("Does that make sense?", true, nil), ("<end>", true, nil)]), channel: .me)
        t.ingest(tokens([("How would you estimate it?", true, nil), ("<end>", true, nil)]), channel: .them)
        t.ingest(tokens([("And why", true, nil)]), channel: .them)
        let w = t.waitingQuestion(handled: [], channelsOnly: true)
        #expect(w?.line.original == "How would you estimate it?")
        #expect(w?.all.count == 2)
        #expect(t.waitingQuestion(handled: Set(w?.all ?? []), channelsOnly: true) == nil)
        #expect(t.waitingQuestion(handled: [], channelsOnly: true, now: .now.addingTimeInterval(500)) == nil)
    }

    @Test func answersSurviveSave() throws {
        let t = Transcript()
        t.answers = [QuestionAnswer(id: 0, question: "Q?", answer: "A.", fromKnowledge: true, createdAt: .now)]
        let back = Transcript(snapshot: try JSONDecoder().decode(TranscriptSnapshot.self, from: JSONEncoder().encode(t.snapshot)))
        #expect(back.answers.first?.answer == "A.")
    }
}

@MainActor
@Suite struct ModeTests {
    @Test func modesChangeHowReadilyLinesAreAnswered() {
        let t = Transcript()
        t.ingest(tokens([("We shipped the pricing model last quarter and it cut losses.", true, nil), ("<end>", true, nil)]), channel: .them)
        #expect(t.waitingQuestion(handled: [], channelsOnly: true, eagerness: .normal) == nil)
        #expect(t.waitingQuestion(handled: [], channelsOnly: true, eagerness: .eager) != nil)

        let talk = Transcript()
        talk.ingest(tokens([("Tell me about a time you failed", true, nil), ("<end>", true, nil)]))
        #expect(talk.waitingQuestion(handled: [], channelsOnly: false, eagerness: .conservative) == nil)
        #expect(talk.waitingQuestion(handled: [], channelsOnly: false, eagerness: .normal) != nil)
    }

    @Test func lectureNotesGrowBySectionWithTerms() {
        let lecture = SummaryPrompt.system(language: "English", detail: .standard, mode: .lecture, extra: "x")
        #expect(lecture.contains("Reply with only the lines to add") && lecture.contains("[Term]") && lecture.contains("## 1.") && lecture.hasSuffix("x"))
        #expect(lecture.contains("**Decision:**"))
        // Meetings use their own tags, not the bold labels.
        let meeting = SummaryPrompt.system(language: "English", mode: .meeting)
        #expect(!meeting.contains("**Decision:**") && meeting.contains("[Decision]"))
        let interview = SummaryPrompt.system(language: "English", mode: .interview)
        #expect(interview.contains("Reply with only the lines to add") && interview.contains("This is an interview"))
        #expect(AnswerPrompt.system(language: "English", mode: .interview).contains("first person"))
        #expect(AnswerPrompt.system(language: "English", mode: .interview, role: "Data Scientist").contains("a Data Scientist position"))
        #expect(AnswerPrompt.system(language: "English", mode: .meeting).contains("When in doubt, SKIP"))
        // A helper turned on by hand works in every mode.
        #expect(AssistantMode.lecture.eagerness == .conservative && AssistantMode.meeting.eagerness == .conservative)
        #expect(AssistantMode.transcribe.eagerness == .normal)
        #expect(AnswerPrompt.system(language: "English", mode: .lecture).contains("This is a talk"))
    }
}


@MainActor
@Suite struct AnswerFilterTests {
    @Test func lectureAnswersNothing() {
        let t = Transcript()
        t.ingest(tokens([("So why does regression to the mean happen?", true, nil), ("<end>", true, nil)]))
        #expect(t.waitingQuestion(handled: [], channelsOnly: false, eagerness: .conservative) != nil)
    }

    @Test func parsesInterviewType() {
        let a = AnswerPrompt.parse("SOURCE: model\nTYPE: technical\nA p-value is…\n- Not P(H0 | data)")
        #expect(a?.kind == "technical" && a?.text == "A p-value is…\n- Not P(H0 | data)" && a?.fromKnowledge == false)
        let b = AnswerPrompt.parse("TYPE: Behavioral\nSOURCE: knowledge\nAt TikTok…")
        #expect(b?.kind == "behavioral" && b?.fromKnowledge == true)
        #expect(AnswerPrompt.parse("SOURCE: model\nTYPE: weird\nText")?.kind == nil)
        #expect(AnswerPrompt.parse("SOURCE: model\nTYPE: technical\nSKIP") == nil)
    }

    @Test func previousQuestionsGoInThePrompt() {
        let u = AnswerPrompt.user(question: "Q", asker: "Them", conversation: "", knowledge: "", previous: ["What is IBNR?"])
        #expect(u.contains("- What is IBNR?") && u.contains("reply SKIP if this only repeats"))
        #expect(!AnswerPrompt.user(question: "Q", asker: "Them", conversation: "", knowledge: "").contains("already answered"))
    }
}


@Suite struct GuideLanguageTests {
    @Test func guideKeepsSpokenWordingAndTerms() {
        let guide = OutputLanguage("Simplified Chinese", spoken: "English")
        #expect(guide.isGuide)
        let summary = SummaryPrompt.system(language: guide, mode: .meeting)
        #expect(summary.contains("Write in Simplified Chinese") && summary.contains("keep in English, exactly as said"))
        let answers = AnswerPrompt.system(language: guide, mode: .interview, role: "Data Scientist")
        #expect(answers.contains("words of Simplified Chinese") && answers.contains("each at most 8 words of English"))
        let meeting = AnswerPrompt.system(language: guide, mode: .meeting)
        #expect(meeting.contains("phrase in English to borrow"))
        #expect(SummaryPrompt.system(language: guide, mode: .lecture).contains("keep in English"))
    }

    @Test func sameLanguageIsNotGuide() {
        #expect(!OutputLanguage("English", spoken: "English").isGuide)
        #expect(AnswerPrompt.system(language: "English").contains("Write in English."))
    }
}


@MainActor
@Suite struct PolishTests {
    @Test func finishedAnswerWaitsForThemOrAPause() {
        let t = Transcript()
        t.ingest(tokens([("Tell me about a project you led.", true, nil), ("<end>", true, nil)]), channel: .them)
        t.ingest(tokens([("So um I led the, the pricing model project at TikTok where we", true, nil), ("<end>", true, nil)]), channel: .me)
        t.ingest(tokens([("we cut the churn by like twelve percent using uplift models.", true, nil), ("<end>", true, nil)]), channel: .me)
        // Still talking for all we know: nothing yet.
        #expect(t.finishedAnswer(handled: [], now: .now) == nil)
        // A pause ends it.
        let paused = t.finishedAnswer(handled: [], now: .now.addingTimeInterval(10))
        #expect(paused?.ids.count == 2 && paused?.question == "Tell me about a project you led.")
        #expect(paused?.text.hasPrefix("So um I led") == true)
        // Them speaking ends it too, and a handled answer isn't returned again.
        t.ingest(tokens([("Interesting.", true, nil), ("<end>", true, nil)]), channel: .them)
        let done = t.finishedAnswer(handled: [])
        #expect(done != nil)
        #expect(t.finishedAnswer(handled: Set(done!.ids)) == nil)
    }

    @Test func shortRepliesArentPolished() {
        let t = Transcript()
        t.ingest(tokens([("Can you hear me?", true, nil), ("<end>", true, nil)]), channel: .them)
        t.ingest(tokens([("Yes, I can.", true, nil), ("<end>", true, nil)]), channel: .me)
        t.ingest(tokens([("Great.", true, nil), ("<end>", true, nil)]), channel: .them)
        #expect(t.finishedAnswer(handled: []) == nil)
    }

    @Test func promptAndParse() {
        let p = PolishPrompt.system(language: OutputLanguage("Simplified Chinese", spoken: "English"), role: "Data Scientist")
        #expect(p.contains("a Data Scientist position") && p.contains("The fix in Simplified Chinese"))
        #expect(PolishPrompt.parse("SKIP") == nil)
        let f = PolishPrompt.parse("STATUS: partial\nUSED: search ranking holdout\nFIX: Add now: \"It lifted sessions 2%.\"\nBETTER: I led the pricing\nproject end to end.")
        #expect(f?.status == "partial" && f?.used == "search ranking holdout" && f?.fix?.hasPrefix("Add now") == true)
        #expect(f?.better == "I led the pricing project end to end.")
        let clean = PolishPrompt.parse("STATUS: complete\nUSED: -\nFIX: -\nBETTER: Fine.")
        #expect(clean?.fix == nil && clean?.used == nil && clean?.status == "complete")
        // Language slips are kept apart from the fix.
        #expect(p.contains("WORDS:"))
        let slips = PolishPrompt.parse("STATUS: complete\nUSED: -\nFIX: Next: lead with the result\nWORDS: I very like it → I really like it | the not equal data → imbalanced data\nBETTER: Fine.")
        #expect(slips?.words == ["I very like it → I really like it", "the not equal data → imbalanced data"])
        #expect(slips?.fix == "Next: lead with the result")
        // They belong to the question answered before them, not to a card of their own.
        let t = Transcript()
        t.answers = [QuestionAnswer(id: 1, question: "Q1?", answer: "A", fromKnowledge: false, createdAt: .now),
                     QuestionAnswer(id: 2, question: "said", answer: "", fromKnowledge: false, createdAt: .now, kind: "polish", words: ["datas → data"]),
                     QuestionAnswer(id: -5, question: "typed", answer: "A", fromKnowledge: false, createdAt: .now, kind: "asked"),
                     QuestionAnswer(id: 3, question: "said", answer: "Next: x", fromKnowledge: false, createdAt: .now, kind: "polish", words: ["a → b"]),
                     QuestionAnswer(id: 4, question: "Q2?", answer: "A", fromKnowledge: false, createdAt: .now)]
        #expect(t.slips == [1: ["datas → data", "a → b"]])
        // An answer to a question that got no card isn't put under the card before it.
        let s = Transcript()
        s.ingest(tokens([("Tell me about a project you led.", true, nil), ("<end>", true, nil)]), channel: .them)
        s.ingest(tokens([("I led the pricing model project.", true, nil), ("<end>", true, nil)]), channel: .me)
        s.ingest(tokens([("Can you hear me okay?", true, nil), ("<end>", true, nil)]), channel: .them)
        s.ingest(tokens([("Yes I hear you very clear.", true, nil), ("<end>", true, nil)]), channel: .me)
        let ids = s.lines.map(\.id)
        s.answers = [QuestionAnswer(id: ids[0], question: "Q", answer: "A", fromKnowledge: false, createdAt: .now),
                     QuestionAnswer(id: ids[1], question: "said", answer: "", fromKnowledge: false, createdAt: .now, kind: "polish", words: ["leaded → led"]),
                     QuestionAnswer(id: ids[3], question: "said", answer: "", fromKnowledge: false, createdAt: .now, kind: "polish", words: ["very clear → very clearly"])]
        #expect(s.slips == [ids[0]: ["leaded → led"]])
        #expect(PolishPrompt.parse("STATUS: complete\nUSED: -\nFIX: -\nWORDS: -\nBETTER: Fine.")?.words == [])
        // An old-style reply still shows as a fix.
        #expect(PolishPrompt.parse("I led the pricing project.\n- like → (drop)")?.fix?.hasPrefix("I led") == true)
        #expect(PolishPrompt.user(question: "Q?", answer: "A", knowledge: "").contains("<question>\nQ?"))
    }
}

@Suite struct EmptyReplyTests {
    @Test func emptyRepliesSayWhy() throws {
        let claude = SummaryEndpoint(provider: .anthropic, baseURL: "", model: "m")
        #expect(throws: SummaryEndpoint.ResponseError.api("The model returned no text (stopped: max_tokens).")) {
            try claude.parse(Data(#"{"content":[{"type":"thinking","thinking":"…"}],"stop_reason":"max_tokens"}"#.utf8))
        }
        #expect(throws: SummaryEndpoint.ResponseError.empty) {
            try claude.parse(Data(#"{"content":[],"stop_reason":"end_turn"}"#.utf8))
        }
        let r = try #require(claude.request(apiKey: "k", system: "s", user: "u"))
        let body = try #require(JSONSerialization.jsonObject(with: r.httpBody!) as? [String: Any])
        #expect(body["thinking"] == nil)
    }
}


@Suite struct AnswerFormatTests {
    @Test func aRestartedReplyKeepsOnlyTheLastAttempt() {
        let reply = "Sure. I'm a data scientist.\nHmm — wait, I should not invent specifics. Corrected version:\nSOURCE: knowledge\nTYPE: motivation\n要点：背景到岗位的连接\n- 背景：\"I started in sociology.\""
        let a = AnswerPrompt.parse(reply)
        #expect(a?.kind == "motivation" && a?.fromKnowledge == true)
        #expect(a?.text.hasPrefix("要点") == true && a?.text.contains("Hmm") == false)
    }

    @Test func guideAnswersPointInChineseAndQuoteEnglish() {
        let p = AnswerPrompt.system(language: OutputLanguage("Simplified Chinese", spoken: "English"), mode: .interview, role: "Data Scientist")
        #expect(p.contains("at most 15 words of Simplified Chinese") && p.contains("starting with ①, ② and ③"))
        #expect(p.contains("⚓ —") && p.contains("north-star metric") && p.contains("Never show your reasoning"))
        let plain = AnswerPrompt.system(language: "English")
        #expect(plain.contains("Write in English.") && !plain.contains("to borrow"))
    }
}

@Suite struct StreamingTests {
    let openAI = SummaryEndpoint(provider: .openAI, baseURL: "", model: "m")
    let claude = SummaryEndpoint(provider: .anthropic, baseURL: "", model: "m")

    @Test func requestAsksForAStream() throws {
        let r = try #require(claude.request(apiKey: "k", system: "s", user: "u", stream: true))
        let body = try #require(JSONSerialization.jsonObject(with: r.httpBody!) as? [String: Any])
        #expect(body["stream"] as? Bool == true)
        let plain = try #require(openAI.request(apiKey: "k", system: "s", user: "u"))
        let plainBody = try #require(JSONSerialization.jsonObject(with: plain.httpBody!) as? [String: Any])
        #expect(plainBody["stream"] == nil)
    }

    @Test func readsOpenAIEvents() {
        #expect(openAI.streamChunk(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#) == .text("Hi"))
        #expect(openAI.streamChunk(#"data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}"#) == nil)
        #expect(openAI.streamChunk(#"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#) == .stop("length"))
        #expect(openAI.streamChunk("data: [DONE]") == .done)
        #expect(openAI.streamChunk(": keep-alive") == nil)
    }

    @Test func readsAnthropicEvents() {
        #expect(claude.streamChunk("event: content_block_delta") == nil)
        #expect(claude.streamChunk(#"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"…"}}"#) == nil)
        #expect(claude.streamChunk(#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"SOURCE"}}"#) == .text("SOURCE"))
        #expect(claude.streamChunk(#"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#) == .stop("max_tokens"))
        #expect(claude.streamChunk(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) == .error("Overloaded"))
        #expect(claude.streamChunk(#"data: {"type":"message_stop"}"#) == .done)
        #expect(throws: SummaryEndpoint.ResponseError.api("The model returned no text (stopped: max_tokens).")) {
            try claude.finish(streamed: "", stop: "max_tokens")
        }
    }

    @Test func partialAnswerWaitsForText() {
        #expect(AnswerPrompt.partial("SOUR") == nil)
        #expect(AnswerPrompt.partial("SOURCE: knowledge\nTYPE: tech") == nil)
        #expect(AnswerPrompt.partial("SOURCE: model\nSK") == nil)
        let p = AnswerPrompt.partial("SOURCE: knowledge\nTYPE: technical\n先给结论")
        #expect(p?.text == "先给结论" && p?.fromKnowledge == true && p?.kind == "technical")
        #expect(PolishPrompt.partial("STATUS: partial\nUSED: -") == nil)
        #expect(PolishPrompt.partial("STATUS: partial\nUSED: -\nFIX: -") == nil)
        #expect(PolishPrompt.partial("STATUS: partial\nUSED: -\nFIX: Add the number") == "Add the number")
        #expect(PolishPrompt.partial("STATUS: complete\nUSED: -\nFIX: -\nWORDS: datas → data") == nil)
    }

    @Test func modesSetTheScene() {
        let off = AssistantMode.Scene(summary: false, answers: false, separatesSpeakers: false, pinsQuestions: false, polishes: nil)
        #expect(AssistantMode.transcribe.scene == off)
        var notes = off
        notes.summary = true
        #expect(AssistantMode.lecture.scene == notes && AssistantMode.meeting.scene == notes)
        let interview = AssistantMode.interview.scene
        #expect(interview.answers && interview.separatesSpeakers && interview.pinsQuestions && interview.polishes == true)
        #expect(!interview.summary)
    }
}

@Suite struct StreamBodyTests {
    @Test func readsAStreamThatArrivedAsOneBody() throws {
        let openAI = SummaryEndpoint(provider: .openAI, baseURL: "", model: "m")
        let body = """
        data: {"choices":[{"delta":{"content":"Hel"}}]}

        data: {"choices":[{"delta":{"content":"lo"}}]}

        data: [DONE]

        """
        #expect(try openAI.parseStreamBody(Data(body.utf8)) == "Hello")
        #expect(try openAI.parseStreamBody(Data(#"{"choices":[]}"#.utf8)) == nil)
    }
}

@Suite struct SourceMemoryTests {
    @Test func turningOnSwitchesToBothAndRemembers() {
        let on = SourceMemory.turningOn(current: "system", both: "both", allowed: true)
        #expect(on.switchTo == "both" && on.remember == "system")
        // Already both, or three-way mode: nothing to switch or remember.
        #expect(SourceMemory.turningOn(current: "both", both: "both", allowed: true).switchTo == nil)
        #expect(SourceMemory.turningOn(current: "system", both: "both", allowed: false).remember == nil)
    }

    @Test func turningOffPutsBackOnlyWhatItReplaced() {
        #expect(SourceMemory.turningOff(current: "both", both: "both", remembered: "system") == "system")
        // Nothing remembered: the user picked both themselves.
        #expect(SourceMemory.turningOff(current: "both", both: "both", remembered: nil as String?) == nil)
        // Changed by hand since: leave it.
        #expect(SourceMemory.turningOff(current: "mic", both: "both", remembered: "system") == nil)
    }
}

@Suite struct TagTests {
    @Test func normalizesTypedTags() {
        #expect(Tags.normalize("  #面试 ") == "面试")
        #expect(Tags.normalize("data   science") == "data science")
        #expect(Tags.normalize(" # ") == nil)
    }

    @Test func addsAndRemovesIgnoringCase() {
        #expect(Tags.adding("Interview", to: ["interview"]) == ["interview"])
        #expect(Tags.adding("#Airwallex", to: ["interview"]) == ["interview", "Airwallex"])
        #expect(Tags.removing("INTERVIEW", from: ["interview", "lecture"]) == ["lecture"])
    }

    @Test func listsTagsByUse() {
        #expect(Tags.all(in: [["b", "a"], ["A"], ["c"]]) == ["a", "b", "c"])
    }

    @Test @MainActor func tagsSurviveSaving() {
        let t = Transcript()
        t.tags = ["面试", "Airwallex"]
        #expect(Transcript(snapshot: t.snapshot).tags == ["面试", "Airwallex"])
        #expect(Transcript().snapshot.tags == nil)
    }
}

@Suite struct SessionBackgroundTests {
    @Test @MainActor func backgroundSurvivesSaving() {
        let t = Transcript()
        #expect(t.snapshot.background == nil)
        t.background = SessionBackground.adding("  和 Irene 的评审会  ", to: t.background)
        t.background = SessionBackground.adding("待办按负责人列出", to: t.background)
        t.background = SessionBackground.adding("   ", to: t.background)
        #expect(t.background == "和 Irene 的评审会\n待办按负责人列出")
        #expect(Transcript(snapshot: t.snapshot).background == t.background)
    }

    @Test func backgroundGoesIntoThePrompts() {
        #expect(SessionBackground.extra(standing: " Felix ", background: " \n") == "Felix")
        let extra = SessionBackground.extra(standing: "Felix", background: "评审会")
        #expect(extra.hasPrefix("Felix\n\n"))
        #expect(extra.contains("<background>\n评审会\n</background>"))
        #expect(SessionBackground.extra(standing: "", background: "评审会").hasPrefix("About this conversation"))
        for prompt in [SummaryPrompt.system(language: "Chinese", extra: extra), AnswerPrompt.system(language: "Chinese", extra: extra)] {
            #expect(prompt.contains("评审会"))
        }
        // Too long: the newest lines are kept, whole.
        let long = (0..<400).map { "line \($0) " + String(repeating: "x", count: 30) }.joined(separator: "\n")
        let cut = SessionBackground.extra(standing: "", background: long)
        #expect(cut.count < SessionBackground.limit + 300)
        #expect(cut.contains("line 399 ") && !cut.contains("line 0 "))
        #expect(cut.contains("<background>\nline "))
        // A long paragraph isn't thrown away for the sake of a clean cut.
        let paragraph = SessionBackground.extra(standing: "", background: String(repeating: "长", count: 7_000) + "\n短")
        #expect(paragraph.count > SessionBackground.limit)
        // The notes take less of it.
        let notes = SessionBackground.extra(standing: "", background: long, limit: SessionBackground.notesLimit)
        #expect(notes.count < SessionBackground.notesLimit + 300 && notes.contains("line 399 "))
    }
}

@Suite struct QuestionLogTests {
    @Test @MainActor func polishesBelongToTheQuestionBeforeThem() {
        let t = Transcript()
        let now = Date.now
        t.answers = [
            QuestionAnswer(id: 1, question: "Tell me about a conflict?", answer: "a", fromKnowledge: true, createdAt: now, kind: "behavioral"),
            QuestionAnswer(id: 2, question: "my answer", answer: "", fromKnowledge: false, createdAt: now, kind: "polish", status: "complete", used: "search holdout"),
            QuestionAnswer(id: 3, question: "p-value vs CI?", answer: "b", fromKnowledge: false, createdAt: now, kind: "technical"),
            QuestionAnswer(id: 4, question: "Questions for us?", answer: "c", fromKnowledge: false, createdAt: now, kind: "reverse"),
        ]
        let log = t.questionLog
        #expect(log.count == 2)
        #expect(log[0].status == "complete" && log[0].used == ["search holdout"])
        #expect(log[1].status == nil)
        t.mode = .interview
        #expect(Transcript(snapshot: t.snapshot).mode == .interview)
    }
}

@Suite struct MeetingTests {
    @Test func readerNamesAreFound() {
        let names = ReaderNames.parse("Felix, Weifeng，刘")
        #expect(names == ["Felix", "Weifeng", "刘"])
        #expect(ReaderNames.mentions("Felix, can you size it?", names: names))
        #expect(ReaderNames.mentions("thanks felix", names: names))
        #expect(!ReaderNames.mentions("Felixstowe office", names: names))
        #expect(ReaderNames.mentions("问一下刘老师", names: names))
        #expect(ReaderNames.promptLine(names).contains("[Action → me]"))
        #expect(ReaderNames.promptLine([]).isEmpty)
    }

    @Test @MainActor func forMeCollectsMentionsAndMyActions() {
        let t = Transcript()
        t.beginStream(channel: .them)
        t.ingest(tokens([("Felix, can you size the churn impact by Friday?", true, "original"), ("<end>", true, nil)], speaker: "1"), channel: .them)
        t.ingest(tokens([("Sure, I'll do it.", true, "original"), ("<end>", true, nil)]), channel: .me)
        t.summary = LiveSummary(text: "## Backlog\n- [Decision] Pause onboarding test\n- [Action → me] Churn-impact estimate, Fri", updatedAt: .now, coveredLineID: 0)
        let items = t.forMe(names: ["Felix"])
        #expect(items.count == 2)
        #expect(items[0].kind == .mention && items[0].text.hasPrefix("Felix, can you"))
        #expect(items[1].kind == .action && items[1].text == "Churn-impact estimate, Fri")
    }

    @Test func meetingPromptsTagAndAnswerQuestionsForMe() {
        #expect(SummaryPrompt.system(language: OutputLanguage("English"), mode: .meeting).contains("[Action → owner]"))
        let a = AnswerPrompt.system(language: OutputLanguage("English"), mode: .meeting)
        #expect(a.contains("TYPE: for-me") && a.contains("① my position"))
        #expect(AnswerPrompt.parse("SOURCE: model\nTYPE: for-me\n① We should wait")?.kind == "for-me")
        #expect(CatchUpPrompt.system(language: OutputLanguage("English")).contains("Now: "))
    }
}

@Suite struct KeyTermTests {
    @Test func termsAreReadFromTheNotes() {
        let notes = "## 1. CUPED\n- Variance drops by ρ²\n- [Term] CUPED — 实验前协变量调整 — uses a pre-period metric as a control variate\n- [Term] control variate — 控制变量"
        let terms = KeyTerm.all(in: notes)
        #expect(terms.count == 2)
        #expect(terms[0] == KeyTerm(term: "CUPED", gloss: "实验前协变量调整", definition: "uses a pre-period metric as a control variate"))
        #expect(terms[1].definition == nil)
        #expect(KeyTerm.isTermLine("- [Term] x — y") && !KeyTerm.isTermLine("- plain"))
    }
}

@Suite struct RecentTextTests {
    @Test @MainActor func takesTheLastMinutes() {
        let t = Transcript()
        t.ingest(tokens([("Earlier topic.", true, nil), ("<end>", true, nil)]))
        t.ingest(tokens([("Latest point.", true, nil), ("<end>", true, nil)]))
        let name: (SpeakerID) -> String = { _ in "S" }
        // Both lines are recent.
        #expect(t.recentText(minutes: 5, name: name).contains("Earlier topic."))
        // Nothing in the window: falls back to the last stretch.
        #expect(t.recentText(minutes: 5, now: .now.addingTimeInterval(3600), name: name).contains("Latest point."))
    }
}

@Suite struct AskTests {
    @Test func promptAndParse() {
        let p = AskPrompt.system(language: OutputLanguage("Simplified Chinese", spoken: "English"), mode: .meeting, extra: "x")
        #expect(p.contains("SOURCE: transcript") && p.contains("in quotes") && p.hasSuffix("x"))
        let u = AskPrompt.user(question: "What did Priya ask me?", conversation: "Priya: can you size it?", notes: "- [Action → me] size it",
                               knowledge: "", previous: [("Who is Priya?", "The PM.")])
        #expect(u.hasSuffix("What did Priya ask me?") && u.contains("<notes>") && u.contains("Q: Who is Priya?"))
        let a = AskPrompt.parse("SOURCE: transcript\n她问你周五前能否估算流失影响。")
        #expect(a?.source == "transcript" && a?.text.hasPrefix("她问你") == true)
        #expect(AskPrompt.parse("SOURCE: knowledge\nYes.")?.source == "knowledge")
        #expect(AskPrompt.parse("Plain answer.")?.source == "model")
        #expect(AskPrompt.partial("SOURCE: trans") == nil)
        #expect(AskPrompt.partial("SOURCE: transcript\nShe")?.text == "She")
    }

    @Test @MainActor func askedQuestionsStayOutOfTheTracker() {
        let t = Transcript()
        t.answers = [QuestionAnswer(id: -5, question: "What did she ask?", answer: "a", fromKnowledge: false, createdAt: .now, kind: "asked", source: "transcript")]
        #expect(t.questionLog.isEmpty)
        #expect(Transcript(snapshot: t.snapshot).answers.first?.source == "transcript")
    }
}

@Suite struct ThinkingRequestTests {
    @Test func deepThinkingPerProvider() throws {
        let claude = SummaryEndpoint(provider: .anthropic, baseURL: "", model: "m")
        let r = try #require(claude.request(apiKey: "k", system: "s", user: "u", maxTokens: 4_000, stream: true, thinking: .budget))
        let body = try #require(JSONSerialization.jsonObject(with: r.httpBody!) as? [String: Any])
        #expect((body["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 5_000 && body["max_tokens"] as? Int == 16_000)
        let a = try #require(claude.request(apiKey: "k", system: "s", user: "u", thinking: .adaptive))
        let ab = try #require(JSONSerialization.jsonObject(with: a.httpBody!) as? [String: Any])
        #expect((ab["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((ab["output_config"] as? [String: Any])?["effort"] as? String == "medium" && ab["budget_tokens"] == nil)
        // Reading a whole session to name the speakers is worth more thinking than a typed question.
        let deep = try #require(claude.request(apiKey: "k", system: "s", user: "u", thinking: .adaptive, effort: .high))
        #expect(((try JSONSerialization.jsonObject(with: deep.httpBody!) as? [String: Any])?["output_config"] as? [String: Any])?["effort"] as? String == "high")
        let old = try #require(claude.request(apiKey: "k", system: "s", user: "u", thinking: .budget, effort: .high))
        #expect(((try JSONSerialization.jsonObject(with: old.httpBody!) as? [String: Any])?["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 10_000)
        #expect(claude.thinkingFallbacks == [.adaptive, .budget, .none])
        #expect(SummaryEndpoint.rejectsThinking(#""thinking.type.enabled" is not supported for this model."#))
        #expect(!SummaryEndpoint.rejectsThinking("invalid x-api-key"))
        let openAI = SummaryEndpoint(provider: .openAI, baseURL: "", model: "m")
        let o = try #require(openAI.request(apiKey: "k", system: "s", user: "u", thinking: .adaptive))
        #expect((try JSONSerialization.jsonObject(with: o.httpBody!) as? [String: Any])?["reasoning_effort"] as? String == "medium")
        let plain = try #require(openAI.request(apiKey: "k", system: "s", user: "u"))
        #expect((try JSONSerialization.jsonObject(with: plain.httpBody!) as? [String: Any])?["reasoning_effort"] == nil)
    }
}

@Suite struct RestatedQuestionTests {
    @Test func questionLineIsAHeader() throws {
        let a = try #require(AnswerPrompt.parse("SOURCE: knowledge\nTYPE: behavioral\nQUESTION: 你和同事对方案有分歧时，当时是怎么处理的？\n先对齐目标\n① Align on goal"))
        #expect(a.question == "你和同事对方案有分歧时，当时是怎么处理的？" && a.kind == "behavioral" && a.text.hasPrefix("先对齐目标"))
        #expect(AnswerPrompt.parse("SOURCE: model\nQUESTION: What is X?\nSKIP") == nil)
        #expect(AnswerPrompt.partial("SOURCE: model\nQUESTION: 你和同事") == nil)
        let p = try #require(AnswerPrompt.partial("SOURCE: model\nQUESTION: What is a p-value?\nThe chance"))
        #expect(p.question == "What is a p-value?" && p.text == "The chance")
        let q = QuestionAnswer(id: 1, question: "We disagreed a lot. How did you handle it?", answer: "a", fromKnowledge: false, createdAt: .now)
        #expect(q.shownQuestion == "How did you handle it?")
        #expect(AnswerPrompt.committed("SOURCE: mo") && !AnswerPrompt.committed("SKI") && !AnswerPrompt.committed(""))
        #expect(AnswerPrompt.user(question: "q", asker: "a", conversation: "", knowledge: "", force: true).contains("never SKIP"))
    }
}

@Suite struct TuningTests {
    let turns: [(id: Int, text: String)] = [
        (1, "可能有一个join的地方，可能需要处理。"),
        (2, "会不会？"),
        (3, "OK，了解。"),
        (4, "那你觉得这一段code要改哪里？"),
    ]

    @Test func cuesAndFloorChangeWhatIsSent() {
        var t = AnswerTuning()
        #expect(t.triggered(turns, eagerness: .eager) == [2, 4])
        t.cues = ["需要处理"]
        t.floor = 10
        #expect(t.triggered(turns, eagerness: .eager) == [1, 4])
    }

    @Test func learnIsSmallAndNeedsTwoSessionsForThresholds() {
        var t = AnswerTuning()
        t.floor = 8
        let review = TuningReview(needed: [1, 4], rules: [
            .init(op: "add", id: nil, text: "During a coding task, treat hints as questions.", why: "missed hint", evidence: [1]),
            .init(op: "add", id: nil, text: "No evidence, not added.", why: "", evidence: []),
            .init(op: "add", id: nil, text: "Third op is ignored.", why: "", evidence: [1]),
        ], cues: ["需要处理", "OK"])
        let changes = t.learn(from: review, turns: turns, eagerness: .eager)
        #expect(t.rules.count == 1 && t.rules[0].trial)
        #expect(t.cues == ["需要处理"])
        // The floor would cut the fragment: noted, not applied yet.
        #expect(t.floor == 8 && t.pendingNudge == .init(setting: .floor, delta: 4))
        #expect(changes.count == 2)
        // A second session agreeing moves it one step; the trial rule is kept.
        _ = t.learn(from: TuningReview(needed: [1, 4]), turns: turns, eagerness: .eager)
        #expect(t.floor == 12 && t.pendingNudge == nil && !t.rules[0].trial)
    }

    @Test func dropTrialRuleAndParse() throws {
        var t = AnswerTuning()
        t.rules = [.init(id: 7, text: "x", why: "", trial: true, added: .now)]
        _ = t.learn(from: TuningReview(drop: [7]), turns: turns, eagerness: .eager)
        #expect(t.rules.isEmpty)
        let r = try #require(TuningPrompt.parse("```json\n{\"needed\": [1, \"4\"], \"rules\": [{\"op\": \"remove\", \"id\": 3, \"why\": \"y\"}], \"cues\": [\"看一下\"]}\n```"))
        #expect(r.needed == [1, 4] && r.rules.first?.op == "remove" && r.rules.first?.id == 3 && r.cues == ["看一下"])
        #expect(AnswerPrompt.system(language: OutputLanguage("Chinese"), mode: .interview, lessons: ["Do X."]).contains("- Do X."))
    }
}

@MainActor @Suite struct ReviewFixTests {
    @Test func summaryWaitsForAnOpenEarlierLine() {
        let t = Transcript()
        // Them is mid-turn while Me finishes a sentence.
        t.ingest(tokens([("So the plan for the launch is", true, nil)]), channel: .them)
        t.ingest(tokens([("Sounds good to me.", true, nil), ("<end>", true, nil)]), channel: .me)
        let first = t.summaryText(after: nil, closedOnly: true, limit: 10_000) { _ in "S" }
        #expect(first.text.isEmpty && first.lastLineID == nil)
        t.ingest(tokens([(" next Tuesday.", true, nil), ("<end>", true, nil)]), channel: .them)
        let second = t.summaryText(after: first.lastLineID, closedOnly: true, limit: 10_000) { _ in "S" }
        #expect(second.text.contains("next Tuesday") && second.text.contains("Sounds good"))
    }

    @Test func skipWithTrailingTextAndBodySourceLines() throws {
        #expect(AnswerPrompt.parse("SKIP - small talk") == nil)
        #expect(AnswerPrompt.parse("Skip: greeting") == nil)
        #expect(AnswerPrompt.parse("SOURCE: model\nSkip the intro and state the result first") != nil)
        let ask = try #require(AskPrompt.parse("SOURCE: transcript\nThey said X\nSource: the meeting"))
        #expect(ask.source == "transcript" && ask.text.contains("They said X"))
        let again = try #require(AskPrompt.parse("SOURCE: model\nfirst try\n\nSOURCE: knowledge\nsecond"))
        #expect(again.source == "knowledge" && again.text == "second")
    }

    @Test func tuningNeedsNeededAndTwoDifferentSessions() {
        #expect(TuningPrompt.parse("{\"rules\": []}") == nil)
        let turns: [(id: Int, text: String)] = [(1, "可能有一个join的地方，可能需要处理。"), (2, "会不会？"), (4, "那你觉得这一段code要改哪里？")]
        var t = AnswerTuning()
        t.floor = 8
        let a = UUID()
        _ = t.learn(from: TuningReview(needed: []), turns: turns, eagerness: .eager, session: a)
        #expect(t.pendingNudge == nil && t.floor == 8)
        _ = t.learn(from: TuningReview(needed: [1, 4]), turns: turns, eagerness: .eager, session: a)
        _ = t.learn(from: TuningReview(needed: [1, 4]), turns: turns, eagerness: .eager, session: a)
        #expect(t.floor == 8)
        _ = t.learn(from: TuningReview(needed: [1, 4]), turns: turns, eagerness: .eager, session: UUID())
        #expect(t.floor == 12)
    }
}

@MainActor @Suite struct SpeakerNameTests {
    func session() -> Transcript {
        let t = Transcript()
        t.ingest(tokens([("Hi, this is Irene.", true, nil), ("<end>", true, nil)], speaker: "1"))
        t.ingest(tokens([("Hello Irene, Roy here. Nice to meet you all.", true, nil), ("<end>", true, nil)], speaker: "2"))
        t.ingest(tokens([("Let me share my screen.", true, nil), ("<end>", true, nil)], speaker: "3"))
        return t
    }

    @Test func sheetParseApplyUndo() throws {
        let t = session()
        let sheet = t.speakerSheet()
        #expect(sheet.tags.count == 3 && sheet.text.contains("[S1 00:00] Hi, this is Irene."))
        let reply = "```json\n{\"speakers\": [{\"tag\": \"S1\", \"person\": \"Irene\", \"confidence\": \"high\", \"why\": \"says 'this is Irene'\"}, {\"tag\": \"S2\", \"person\": \"Roy\", \"confidence\": \"medium\", \"why\": \"Roy here\"}, {\"tag\": \"S3\", \"person\": \"irene\", \"confidence\": \"low\", \"why\": \"continues\"}, {\"tag\": \"S9\", \"person\": \"X\"}], \"note\": \"\"}\n```"
        let parsed = try #require(SpeakerPrompt.parse(reply, tags: sheet.tags))
        #expect(parsed.proposals.count == 3 && parsed.proposals[2].confidence == .low)
        #expect(t.apply(parsed.proposals) == 3)
        #expect(t.visibleSpeakers.count == 2 && t.visibleSpeakers.map(\.name) == ["Irene", "Roy"])
        #expect(t.speakerBackup != nil)
        // Saved and reopened, it can still be undone.
        let again = Transcript(snapshot: t.snapshot)
        again.undoSpeakerNames()
        #expect(again.visibleSpeakers.count == 3 && again.visibleSpeakers.allSatisfy { $0.name.isEmpty } && again.speakerBackup == nil)
        t.resetSpeakers()
        #expect(t.visibleSpeakers.count == 3 && !t.hasSpeakerEdits)
    }

    @Test func placeholdersMergeWithoutNamingAndSidesStayApart() {
        let t = session()
        let ids = t.visibleSpeakers.map(\.id)
        t.apply([.init(id: ids[0], tag: "S1", person: "?A", confidence: .medium, why: ""),
                 .init(id: ids[2], tag: "S3", person: "?A", confidence: .medium, why: "")])
        #expect(t.visibleSpeakers.count == 2 && t.visibleSpeakers.allSatisfy { $0.name.isEmpty })

        let call = Transcript()
        call.ingest(tokens([("I am Felix.", true, nil), ("<end>", true, nil)]), channel: .me)
        call.ingest(tokens([("And I am Irene.", true, nil), ("<end>", true, nil)]), channel: .them)
        let both = call.visibleSpeakers.map(\.id)
        call.apply(both.map { .init(id: $0, tag: "S", person: "Felix", confidence: .high, why: "") })
        #expect(call.visibleSpeakers.count == 2)
        #expect(SpeakerHints.parseNames("Irene，Roy; Preethi\nFelix") == ["Irene", "Roy", "Preethi", "Felix"])

        let s = session()
        let three = s.visibleSpeakers.map(\.id)
        s.speakerSuggestions = [.init(id: three[0], tag: "S1", person: "Irene", confidence: .high, why: ""),
                                .init(id: three[1], tag: "S2", person: "?A", confidence: .low, why: ""),
                                .init(id: three[2], tag: "S3", person: "Irene", confidence: .medium, why: "")]
        #expect(s.suggestion(for: three[1]) == nil && s.suggestion(for: three[0])?.person == "Irene")
        s.acceptSuggestion(for: three[0])
        #expect(s.visibleSpeakers.count == 2 && s.speakerSuggestions.count == 1)
        #expect(Transcript(snapshot: s.snapshot).speakerSuggestions.count == 1)
    }

    @Test func acceptingLeavesLowConfidenceNamesakes() {
        let t = session()
        let ids = t.visibleSpeakers.map(\.id)
        t.speakerSuggestions = [.init(id: ids[0], tag: "S1", person: "Irene", confidence: .high, why: ""),
                                .init(id: ids[2], tag: "S3", person: "irene", confidence: .low, why: "")]
        t.acceptSuggestion(for: ids[0])
        // The low guess about someone else is still theirs to take.
        #expect(t.visibleSpeakers.count == 3 && t.visibleSpeakers.map(\.name) == ["Irene", "", ""])
        #expect(t.suggestion(for: ids[2])?.person == "irene" && t.speakerSuggestions.count == 1)
        // Taking it themselves joins the Irene already there.
        t.acceptSuggestion(for: ids[2])
        #expect(t.visibleSpeakers.map(\.id) == [ids[0], ids[1]] && t.visibleSpeakers.map(\.name) == ["Irene", ""])
        #expect(t.speakerSuggestions.isEmpty)
    }

    @Test func applyJoinsSomeoneAlreadyNamedOnTheSameSide() {
        let t = session()
        let ids = t.visibleSpeakers.map(\.id)
        t.rename(ids[0], to: "Irene")
        #expect(t.apply([.init(id: ids[2], tag: "S3", person: "IRENE", confidence: .high, why: "")]) == 1)
        // Merged into the one who had the name, who keeps it as written.
        #expect(t.visibleSpeakers.map(\.id) == [ids[0], ids[1]] && t.visibleSpeakers.map(\.name) == ["Irene", ""])
        // A placeholder names nobody, so it never joins someone by name.
        t.resetSpeakers()
        t.rename(ids[0], to: "?A")
        t.apply([.init(id: ids[2], tag: "S3", person: "?A", confidence: .high, why: "")])
        #expect(t.visibleSpeakers.count == 3)

        // The other side of the call is someone else, whatever they are called.
        let call = Transcript()
        call.ingest(tokens([("I am Felix.", true, nil), ("<end>", true, nil)]), channel: .me)
        call.ingest(tokens([("So am I.", true, nil), ("<end>", true, nil)]), channel: .them)
        let both = call.visibleSpeakers.map(\.id)
        call.rename(both[0], to: "Felix")
        call.apply([.init(id: both[1], tag: "S2", person: "felix", confidence: .high, why: "")])
        #expect(call.visibleSpeakers.count == 2 && call.visibleSpeakers.map(\.name) == ["Felix", "felix"])
        // A placeholder shared only across the two sides is not worth showing; one shared on a side is, in any case.
        call.resetSpeakers()
        call.speakerSuggestions = both.map { .init(id: $0, tag: "S", person: "?A", confidence: .medium, why: "") }
        #expect(both.allSatisfy { call.suggestion(for: $0) == nil })
        let s = session()
        let three = s.visibleSpeakers.map(\.id)
        s.speakerSuggestions = [.init(id: three[0], tag: "S1", person: "?A", confidence: .medium, why: ""),
                                .init(id: three[2], tag: "S3", person: "?a", confidence: .medium, why: "")]
        #expect(s.suggestion(for: three[0]) != nil && s.suggestion(for: three[2]) != nil)
    }

    @Test func undoOffersTakenSuggestionsAgain() {
        let t = session()
        let ids = t.visibleSpeakers.map(\.id)
        let offered: [SpeakerProposal] = [.init(id: ids[0], tag: "S1", person: "Irene", confidence: .high, why: ""),
                                          .init(id: ids[1], tag: "S2", person: "Roy", confidence: .medium, why: ""),
                                          .init(id: ids[2], tag: "S3", person: "Irene", confidence: .medium, why: "")]
        t.speakerSuggestions = offered
        t.acceptSuggestion(for: ids[0])
        #expect(t.speakerSuggestions.map(\.id) == [ids[1]])
        #expect(t.snapshot.speakerSuggestionsTaken?.count == 2)
        // Saved and reopened, undoing still puts them back on offer.
        let again = Transcript(snapshot: t.snapshot)
        again.undoSpeakerNames()
        #expect(Set(again.speakerSuggestions.map(\.id)) == Set(ids) && again.speakerSuggestions.count == 3)
        #expect(ids.allSatisfy { again.suggestion(for: $0) != nil })
        #expect(again.snapshot.speakerSuggestionsTaken == nil)
        // A second undo has nothing to bring back.
        again.undoSpeakerNames()
        #expect(again.speakerSuggestions.count == 3)

        // Resetting forgets what was taken.
        t.resetSpeakers()
        #expect(t.snapshot.speakerSuggestionsTaken == nil)
        t.undoSpeakerNames()
        #expect(t.speakerSuggestions.map(\.id) == [ids[1]])
    }
}
