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

    @Test func lectureKeepsARewrittenOverview() {
        #expect(AssistantMode.lecture.rewritesSummary && !AssistantMode.meeting.rewritesSummary && !AssistantMode.interview.rewritesSummary)
        let lecture = SummaryPrompt.system(language: "English", detail: .standard, mode: .lecture, extra: "x")
        #expect(lecture.contains("complete updated summary") && lecture.contains("## Main points: at most 8") && lecture.hasSuffix("x"))
        let interview = SummaryPrompt.system(language: "English", mode: .interview)
        #expect(interview.contains("Reply with only the lines to add") && interview.contains("This is an interview"))
        #expect(AnswerPrompt.system(language: "English", mode: .interview).contains("first person"))
        #expect(AnswerPrompt.system(language: "English", mode: .interview, role: "Data Scientist").contains("a Data Scientist position"))
        #expect(AnswerPrompt.system(language: "English", mode: .meeting).contains("When in doubt, SKIP"))
        #expect(AssistantMode.lecture.eagerness == .off && AssistantMode.meeting.eagerness == .conservative)
        let p = SummaryPrompt.overview(current: LiveSummary(text: "## Main points\n- a", updatedAt: .now, coveredLineID: 0, context: "A talk."), newTranscript: "S: more")
        #expect(p.contains("CONTEXT: A talk.\n## Main points\n- a"))
        #expect(SummaryPrompt.shouldUpdateOverview(newWeight: 1000, sinceUpdate: 1) && !SummaryPrompt.shouldUpdateOverview(newWeight: 300, sinceUpdate: 20))
    }
}


@MainActor
@Suite struct AnswerFilterTests {
    @Test func lectureAnswersNothing() {
        let t = Transcript()
        t.ingest(tokens([("So why does regression to the mean happen?", true, nil), ("<end>", true, nil)]))
        #expect(t.waitingQuestion(handled: [], channelsOnly: false, eagerness: .off) == nil)
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
        #expect(answers.contains("words of Simplified Chinese") && answers.contains("phrase in English to borrow"))
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
        #expect(p.contains("a Data Scientist position") && p.contains("Bullets in Simplified Chinese"))
        #expect(PolishPrompt.parse("SKIP") == nil)
        #expect(PolishPrompt.parse("I led the pricing project.\n- like → (drop)") != nil)
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
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
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
        #expect(p.contains("at most 15 words of Simplified Chinese") && p.contains("short phrase in English to borrow"))
        #expect(p.contains("No full answer paragraph") && p.contains("Never show your reasoning"))
        let plain = AnswerPrompt.system(language: "English")
        #expect(plain.contains("Write in English.") && !plain.contains("to borrow"))
    }
}
