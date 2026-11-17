import AppKit
import LukaCore
import SwiftUI

enum CaptionStyle: String, CaseIterable, Sendable {
    case glass, clear, dark
}

enum CaptionVisibility: String, CaseIterable, Sendable {
    /// Captions come and go with listening.
    case whileListening
    /// Captions stay where you left them; toggle by hand.
    case always
}

@MainActor
@Observable
final class AppModel {
    enum Status: Equatable {
        case idle, connecting, live, paused, reconnecting
        /// Paused by itself because it went quiet; capture keeps running locally to notice sound again.
        case standby
        case error(String)
    }

    let store = SessionStore()
    /// The session audio goes into. Captions always show this one.
    private(set) var transcript = Transcript()
    /// The session shown in the transcript window.
    var selectedID: UUID?
    @ObservationIgnored private var autosave: Timer?
    @ObservationIgnored var openTranscript: () -> Void = {}
    @ObservationIgnored var closeTranscript: () -> Void = {}
    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored let client = SonioxStreams()
    /// The live summary, on its own model and key.
    let summarizer = Summarizer()
    @ObservationIgnored private var summaryTimer: Timer?
    @ObservationIgnored private var accountTimer: Timer?
    @ObservationIgnored let audio = AudioPipeline()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var idleDisconnect: DispatchWorkItem?
    @ObservationIgnored private var quiet: QuietGate
    /// The last 2 s heard during standby, sent on waking so the first words aren't lost.
    /// Each chunk keeps its Me / Them lane, or nil when every stream hears it.
    @ObservationIgnored private var preroll: [(data: Data, lane: Int?)] = []
    /// Whether the open streams are Me / Them: set when they connect, so audio routes to match.
    @ObservationIgnored private var splitActive = false
    /// The microphone's latest level in Me / Them mode, so either voice keeps the session awake.
    @ObservationIgnored private var micLevel: Float = 0
    @ObservationIgnored let feedFile: URL?

    private(set) var status: Status = .idle { didSet { if status != oldValue { followStatusWithCaptions() } } }
    private(set) var level: Float = 0
    private(set) var startedAt: Date?

    var apiKey: String {
        didSet {
            SecretStore.save(apiKey)
            if apiKey != oldValue { checkKey(after: .milliseconds(600)) }
        }
    }
    /// Where the key's Soniox project lives. Found from the key, never chosen.
    private(set) var region: SonioxRegion {
        didSet {
            store(region.rawValue, "region")
            if region != oldValue { streamSettingsChanged() }
        }
    }

    var mode: TranslationMode { didSet { store(mode.rawValue, "mode"); if separatesSpeakers { routingChanged() } else { streamSettingsChanged() } } }
    /// Soniox code, or "auto".
    var source: String { didSet { store(source, "source"); streamSettingsChanged() } }
    var target: String { didSet { store(target, "target"); streamSettingsChanged() } }
    var languageA: String { didSet { store(languageA, "languageA"); streamSettingsChanged() } }
    var languageB: String { didSet { store(languageB, "languageB"); streamSettingsChanged() } }
    var languageC: String { didSet { store(languageC, "languageC"); streamSettingsChanged() } }
    var context: String { didSet { store(context, "context") } }
    var audioSource: AudioSource {
        didSet {
            store(audioSource.rawValue, "audioSource")
            if separatesSpeakers { routingChanged() } else { audioSourceChanged() }
        }
    }
    /// Me / Them: with Mac audio + microphone, transcribe each on its own stream, so the microphone
    /// is always you and the Mac audio is always them. Costs a second stream.
    var separatesSpeakers: Bool { didSet { store(separatesSpeakers, "separatesSpeakers"); routingChanged() } }
    /// In Me / Them mode, whether your own words are translated too, or only written down.
    var translatesMyVoice: Bool { didSet { store(translatesMyVoice, "translatesMyVoice"); if splitsBySource { streamSettingsChanged() } } }
    /// Keep the latest question someone asked above the captions.
    var pinsQuestions: Bool { didSet { store(pinsQuestions, "pinsQuestions") } }
    /// The pinned question the user closed; it stays closed until a new one is asked.
    var dismissedQuestion: Int?
    /// Me / Them applies to Mac audio + microphone, outside three-way mode (which already runs a stream per language).
    var splitsBySource: Bool { separatesSpeakers && audioSource == .both && mode != .threeWay }

    // Usage: audio sent to Soniox, to estimate the bill.
    private(set) var sessionUsage = UsageTotals()
    private(set) var monthUsage = UsageTotals()
    private(set) var lastMonthUsage = UsageTotals()
    /// Counted on every chunk, published every few seconds so views don't redraw ten times a second.
    @ObservationIgnored private var pendingUsage = UsageTotals()

    // What Soniox itself reports: this project's real cost this month (project key),
    // and the prepaid balance (needs an organization key, snx_org_…).
    private(set) var accountMonthCost: Double?
    private(set) var accountBalance: SonioxAccount.Balance?
    private(set) var accountError: String?
    private(set) var accountCheckedAt: Date?
    var orgKey: String {
        didSet {
            SecretStore.save(orgKey, slot: "org")
            if orgKey != oldValue { accountBalance = nil; refreshAccount() }
        }
    }
    /// Core Audio UID of the chosen input device; nil follows the system default.
    var microphone: String? {
        didSet {
            guard microphone != oldValue else { return }
            if let microphone { store(microphone, "microphone") } else { defaults.removeObject(forKey: "microphone") }
            if audioSource != .system { audioSourceChanged() }
        }
    }
    var pausesWhenQuiet: Bool {
        didSet {
            store(pausesWhenQuiet, "pausesWhenQuiet")
            quiet.reset()
            if !pausesWhenQuiet, status == .standby { wake() }
        }
    }

    var captionLines: Int { didSet { store(captionLines, "captionLines") } }
    var captionFontSize: Double { didSet { store(captionFontSize, "captionFontSize") } }
    var captionShowsOriginal: Bool { didSet { store(captionShowsOriginal, "captionShowsOriginal") } }
    /// In three-way mode, the one translation captions show; empty shows them all.
    var captionLanguage: String { didSet { store(captionLanguage, "captionLanguage") } }
    /// `captionLanguage` when it applies: three-way mode, and still one of its languages.
    var captionLanguageFilter: String? {
        mode == .threeWay && sessionConfig.threeWayLanguages.contains(captionLanguage) ? captionLanguage : nil
    }
    var captionStyle: CaptionStyle { didSet { store(captionStyle.rawValue, "captionStyle") } }
    var captionPinned: Bool { didSet { store(captionPinned, "captionPinned") } }
    var transcriptFontSize: Double { didSet { store(transcriptFontSize, "transcriptFontSize") } }
    var transcriptShowsOriginal: Bool { didSet { store(transcriptShowsOriginal, "transcriptShowsOriginal") } }
    var transcriptPinned: Bool { didSet { store(transcriptPinned, "transcriptPinned") } }
    var presenterFontSize: Double { didSet { store(presenterFontSize, "presenterFontSize") } }

    var showsInDock: Bool { didSet { store(showsInDock, "showsInDock"); applyActivationPolicy() } }
    var liquidGlass: Bool { didSet { store(liquidGlass, "liquidGlass") } }
    /// Liquid Glass needs macOS 26; before that, and when turned off, Luka draws system materials.
    var usesGlass: Bool { LukaGlassSupport.available && liquidGlass }

    var captionVisibility: CaptionVisibility {
        didSet {
            store(captionVisibility.rawValue, "captionVisibility")
            captionsHiddenByUser = false
            followStatusWithCaptions()
        }
    }
    private(set) var captionsVisible: Bool
    @ObservationIgnored private var captionsHiddenByUser = false
    @ObservationIgnored private var captionsAutoHide: DispatchWorkItem?
    var transcriptVisible = false
    var presenterVisible = false
    var locked = false
    var renaming: RenameRequest?
    var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    static let captionLineRange = 1...6
    static let captionFontRange = 14.0...64.0
    static let transcriptFontRange = 11.0...28.0
    static let presenterFontRange = 20.0...96.0

    init() {
        let d = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        apiKey = SecretStore.read() ?? env["SONIOX_API_KEY"] ?? ""
        let storedRegion = SonioxRegion(rawValue: d.string(forKey: "region") ?? "")
        region = storedRegion ?? .us
        let preferred = Localizer.shared.resolved.rawValue
        mode = TranslationMode(rawValue: d.string(forKey: "mode") ?? "") ?? .translate
        source = d.string(forKey: "source") ?? "auto"
        target = d.string(forKey: "target") ?? preferred
        let a = d.string(forKey: "languageA") ?? (preferred == "en" ? "ko" : "en")
        let b = d.string(forKey: "languageB") ?? preferred
        languageA = a
        languageB = b
        languageC = d.string(forKey: "languageC") ?? (["en", "ko", "zh"].first { $0 != a && $0 != b } ?? "ja")
        context = d.string(forKey: "context") ?? ""
        audioSource = AudioSource(rawValue: d.string(forKey: "audioSource") ?? "") ?? .system
        separatesSpeakers = d.bool(forKey: "separatesSpeakers")
        translatesMyVoice = d.object(forKey: "translatesMyVoice") == nil ? true : d.bool(forKey: "translatesMyVoice")
        pinsQuestions = d.bool(forKey: "pinsQuestions")
        orgKey = SecretStore.read("org") ?? ""
        microphone = d.string(forKey: "microphone")
        pausesWhenQuiet = d.object(forKey: "pausesWhenQuiet") == nil ? true : d.bool(forKey: "pausesWhenQuiet")
        quiet = QuietGate(sleepAfterSeconds: d.object(forKey: "quietSeconds") == nil ? 180 : d.integer(forKey: "quietSeconds"))
        captionLines = d.object(forKey: "captionLines") as? Int ?? 2
        captionFontSize = d.object(forKey: "captionFontSize") as? Double ?? 24
        captionShowsOriginal = d.bool(forKey: "captionShowsOriginal")
        captionLanguage = d.string(forKey: "captionLanguage") ?? ""
        captionStyle = CaptionStyle(rawValue: d.string(forKey: "captionStyle") ?? "") ?? .glass
        captionPinned = d.object(forKey: "captionPinned") as? Bool ?? true
        transcriptFontSize = d.object(forKey: "transcriptFontSize") as? Double ?? 15
        transcriptShowsOriginal = d.object(forKey: "transcriptShowsOriginal") as? Bool ?? true
        transcriptPinned = d.bool(forKey: "transcriptPinned")
        presenterFontSize = d.object(forKey: "presenterFontSize") as? Double ?? 40
        showsInDock = d.object(forKey: "showsInDock") as? Bool ?? true
        liquidGlass = d.object(forKey: "liquidGlass") == nil ? true : d.bool(forKey: "liquidGlass")
        let visibility = CaptionVisibility(rawValue: d.string(forKey: "captionVisibility") ?? "") ?? .whileListening
        captionVisibility = visibility
        captionsVisible = visibility == .always ? d.object(forKey: "captionsVisible") as? Bool ?? true : false

        let args = ProcessInfo.processInfo.arguments
        feedFile = args.firstIndex(of: "--feed").flatMap { args.indices.contains($0 + 1) ? URL(fileURLWithPath: args[$0 + 1]) : nil }

        client.onEvent = { [weak self] lane, event in
            guard let self else { return }
            if self.splitActive {
                self.handle(event, channel: lane == 1 ? .me : .them)
            } else if lane == 0 {
                self.handle(event)
            } else {
                self.handleTranslation(event, lane: lane)
            }
        }
        client.onUsage = { [weak self] ms, translated in self?.pendingUsage.add(ms: ms, translated: translated) }
        client.carryover = { [weak self] in self?.transcript.recentContext() }
        audio.onChunk = { [weak self] data, level, channel in
            Task { @MainActor in self?.heard(data, level: level, channel: channel) }
        }
        let now = Date.now
        monthUsage = Self.loadUsage(UsageTotals.monthKey(now))
        lastMonthUsage = Self.loadUsage(UsageTotals.monthKey(Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now))
        store.track(transcript)
        selectedID = transcript.id
        if hasKey, storedRegion == nil { checkKey(after: .zero) }
        summaryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickSummary() }
        }
        accountTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccount() }
        }
        refreshAccount()
        autosave = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveLive()
                self?.flushUsage()
            }
        }
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showsInDock ? .regular : .accessory)
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: Session

    var hasKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
    var isListening: Bool { [.live, .connecting, .reconnecting, .standby].contains(status) }

    var sessionConfig: SessionConfig {
        SessionConfig(mode: mode, source: source == "auto" ? nil : source, target: target,
                      languageA: languageA, languageB: languageB, languageC: languageC, context: context)
    }

    func toggleListening() {
        if isListening { pause() } else { start() }
    }

    func start() {
        guard hasKey else {
            show(tr("Add your Soniox API key in Settings first."))
            return
        }
        idleDisconnect?.cancel()
        quiet.reset()
        preroll.removeAll()
        retriedRegion = false
        if !client.isOpen {
            status = .connecting
            connectStream()
        } else {
            status = .live
        }
        if startedAt == nil { startedAt = .now }
        transcript.markStarted()
        Task {
            do {
                try await audio.start(audioSource, microphone: microphone, feedFile: feedFile, separate: splitsBySource)
            } catch {
                client.disconnect()
                status = .error(error.localizedDescription)
            }
        }
    }

    func pause() {
        audio.stop()
        level = 0
        guard client.isOpen else {
            status = .idle
            return
        }
        client.send(audio: AudioPipeline.silence(milliseconds: 300))
        client.finalize()
        status = .paused
        disconnectSoon()
    }

    /// Soniox bills while a stream is open, so a pause keeps it only long enough for a quick resume.
    private func disconnectSoon() {
        idleDisconnect?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, [.paused, .standby].contains(self.status) else { return }
            self.client.disconnect()
        }
        idleDisconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func heard(_ data: Data, level: Float, channel: CaptureChannel = .mixed) {
        // Me / Them: the microphone goes to lane 1, the Mac audio to lane 0. Audio still separated
        // after the streams went back to one (a setting just changed) goes to every stream.
        let lane: Int? = splitActive && channel != .mixed ? (channel == .microphone ? 1 : 0) : nil
        // Two sources hand out twice the chunks: only the Mac audio's drive the meter and the quiet
        // clock, using the louder of the two, so either voice keeps the session awake.
        var level = level
        if channel == .microphone, lane != nil { micLevel = level; return send(data, lane: lane, gate: nil) }
        if lane != nil { level = max(level, micLevel) }
        self.level = level
        send(data, lane: lane, gate: level)
    }

    /// `gate` is the level for the quiet clock, or nil for audio that doesn't drive it.
    private func send(_ data: Data, lane: Int?, gate level: Float?) {
        let keep = splitActive ? 2 : 1
        if findingRegion {
            // Held while the key's region is looked up, then sent, like waking from standby.
            preroll.append((data, lane))
            if preroll.count > 50 * keep { preroll.removeFirst() }
            return
        }
        guard pausesWhenQuiet else {
            client.send(audio: data, lane: lane)
            return
        }
        if status == .standby {
            preroll.append((data, lane))
            if preroll.count > 20 * keep { preroll.removeFirst() }
            if let level, quiet.wake(level: level) { wake() }
            return
        }
        client.send(audio: data, lane: lane)
        if let level, status == .live, quiet.listen(level: level) { standBy() }
    }

    private func standBy() {
        AudioLog.write("quiet for \(quiet.sleepAfter / 10) s: standby")
        client.finalize()
        status = .standby
        quiet.reset()
        disconnectSoon()
    }

    private func wake() {
        AudioLog.write("sound again: resuming")
        idleDisconnect?.cancel()
        quiet.reset()
        if client.isOpen {
            status = .live
        } else {
            status = .connecting
            connectStream()
        }
        preroll.forEach { client.send(audio: $0.data, lane: $0.lane) }
        preroll.removeAll()
    }

    /// Saves the current session and opens a fresh one.
    func newSession(start startNow: Bool = false) {
        endSession()
        if transcript.hasStarted || transcript.id != selectedID {
            transcript = Transcript()
            store.track(transcript)
            resetSessionUsage()
        }
        selectedID = transcript.id
        if startNow { start() }
    }

    /// Makes an older session the live one and starts listening into it.
    func continueSession(_ t: Transcript) {
        if t.id != transcript.id {
            endSession()
            transcript = t
            resetSessionUsage()
        }
        selectedID = t.id
        start()
    }

    /// Stops listening and closes the stream. Starting again continues the same session.
    func endSession() {
        audio.stop()
        client.disconnect()
        idleDisconnect?.cancel()
        level = 0
        status = .idle
        startedAt = nil
        renaming = nil
        transcript.clearProvisional()
        store.save(transcript)
        flushUsage()
        summarizer.catchUp(transcript, languageName: summaryLanguageName, name: { [weak self] in self?.speakerName($0) ?? "" })
        // Soniox's own numbers lag a little; look again once this session has been billed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.refreshAccount() }
    }

    func saveLive() {
        store.save(transcript)
    }

    var selectedTranscript: Transcript? {
        guard let id = selectedID else { return nil }
        return id == transcript.id ? transcript : store.transcript(id)
    }

    func isLive(_ t: Transcript) -> Bool { t.id == transcript.id }

    func deleteSession(_ id: UUID) {
        if id == transcript.id {
            endSession()
            transcript = Transcript()
            store.track(transcript)
        }
        store.delete(id)
        if selectedID == id { selectedID = transcript.id }
    }

    func title(_ t: Transcript) -> String {
        t.title.isEmpty ? Self.defaultTitle(t) : t.title
    }

    /// Until listening starts, a session has no meaningful time, so it is just "New Session".
    static func defaultTitle(_ t: Transcript) -> String {
        t.hasStarted ? defaultTitle(t.createdAt) : tr("New Session")
    }

    static func defaultTitle(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Localizer.shared.locale))
    }

    func copy(_ t: Transcript) {
        let text = t.plainText(name: { self.speakerName($0, in: t) }, includeOriginal: transcriptShowsOriginal)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(tr("Copied transcript"))
    }

    /// `channel` is set for Me / Them streams.
    private func handle(_ event: SonioxClient.Event, channel: Channel? = nil) {
        switch event {
        case .connected:
            transcript.beginStream(channel: channel)
            if status == .connecting || status == .reconnecting { status = .live }
        case .response(let response, let baseMs):
            if response.tokens.contains(where: { !$0.isMarker }) { quiet.heardSpeech() }
            transcript.ingest(response, baseMs: baseMs, channel: channel)
        case .reconnecting:
            if ![.paused, .standby].contains(status) { status = .reconnecting }
        case .failed(let error):
            fail(error)
        }
    }

    /// Events from three-way mode's extra streams, which only add translations.
    private func handleTranslation(_ event: SonioxClient.Event, lane: Int) {
        switch event {
        case .response(let response, let baseMs):
            transcript.ingestTranslation(response, lane: lane, baseMs: baseMs)
        case .failed(let error):
            fail(error)
        case .connected, .reconnecting:
            break
        }
    }

    private func fail(_ error: SonioxClient.SonioxError) {
        if error == .invalidKey {
            // Every stream reports the same rejection; the first one decides.
            if findingRegion { return }
            if !retriedRegion {
                retryInKeysRegion()
                return
            }
        }
        audio.stop()
        client.disconnect()
        level = 0
        status = .error(Self.message(for: error))
    }

    private func streamSettingsChanged() {
        guard client.isOpen else { return }
        let resume = isListening
        client.disconnect()
        transcript.clearProvisional()
        // Standby wakes into a fresh stream with the new settings.
        if status == .standby { return }
        if resume {
            status = .connecting
            connectStream()
        } else {
            status = .idle
        }
    }

    // MARK: Key and region

    enum KeyState: Equatable {
        case idle, checking, invalid, unreachable
    }

    private(set) var keyState: KeyState = .idle
    @ObservationIgnored private var keyCheck: Task<Void, Never>?
    /// The key `keyCheck` already covers, so saving a verified key doesn't check it again.
    @ObservationIgnored private var checkedKey: String?
    @ObservationIgnored private var findingRegion = false
    @ObservationIgnored private var retriedRegion = false

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespaces) }

    /// Checks the key in every region and keeps the one that accepts it.
    private func checkKey(after delay: Duration) {
        let key = trimmedKey
        guard key != checkedKey else { return }
        keyCheck?.cancel()
        guard !key.isEmpty else {
            keyState = .idle
            keyCheck = nil
            return
        }
        keyState = .checking
        keyCheck = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let result = await KeyCheck.run(key)
            guard !Task.isCancelled else { return }
            apply(result, for: key)
            keyCheck = nil
        }
    }

    private func apply(_ result: KeyCheck.Result, for key: String) {
        checkedKey = key
        retriedRegion = false
        AudioLog.write("key check: \(result)")
        switch result {
        case .region(let found):
            region = found
            keyState = .idle
        case .invalid:
            keyState = .invalid
        case .unreachable:
            keyState = .unreachable
        }
    }

    /// The first-run key field: keeps the key only if Soniox accepts it somewhere.
    func submitKey(_ key: String) async -> KeyCheck.Result {
        keyCheck?.cancel()
        keyState = .checking
        let result = await KeyCheck.run(key)
        apply(result, for: key)
        if result != .invalid { apiKey = key }
        return result
    }

    /// Opens the streams, after a key check in flight has settled the region.
    private func connectStream() {
        guard let pending = keyCheck else {
            openStreams()
            return
        }
        Task {
            await pending.value
            guard status == .connecting else { return }
            openStreams()
        }
    }

    private func openStreams() {
        let config = sessionConfig
        splitActive = splitsBySource
        micLevel = 0
        client.connect(apiKey: trimmedKey, region: region, config: config,
                       myVoice: splitActive ? config.forMyVoice(translate: translatesMyVoice) : nil)
    }

    /// Settings that change both where audio goes and which streams it goes to.
    private func routingChanged() {
        streamSettingsChanged()
        audioSourceChanged()
    }

    /// A rejected key may belong to another region: look it up once and reconnect there.
    private func retryInKeysRegion() {
        findingRegion = true
        retriedRegion = true
        client.disconnect()
        status = .connecting
        let key = trimmedKey
        preroll.removeAll()
        Task {
            let result = await KeyCheck.run(key)
            findingRegion = false
            guard status == .connecting else { return }
            if case .region(let found) = result, found != region {
                AudioLog.write("key belongs to region \(found.rawValue): reconnecting")
                apply(result, for: key)
                connectStream()
                preroll.forEach { client.send(audio: $0.data, lane: $0.lane) }
                preroll.removeAll()
                return
            }
            if result == .invalid { keyState = .invalid }
            fail(result == .unreachable ? .network(tr("Couldn’t reach Soniox.")) : .invalidKey)
        }
    }

    private func audioSourceChanged() {
        guard audio.isRunning else { return }
        Task {
            do {
                try await audio.start(audioSource, microphone: microphone, feedFile: feedFile, separate: splitsBySource)
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    private static func message(for error: SonioxClient.SonioxError) -> String {
        switch error {
        case .invalidKey: tr("Soniox doesn’t recognize this API key. Check it in Settings.")
        case .noCredits: tr("Your Soniox account is out of credits.")
        case .rateLimited: tr("Soniox is rate limiting this key. Try again in a moment.")
        case .config(let m): String(format: tr("Soniox didn’t accept the settings: %@"), m)
        case .network(let m): String(format: tr("Connection lost: %@"), m)
        }
    }

    // MARK: Presentation

    func show(_ message: String) {
        noticeTask?.cancel()
        withAnimation(.smooth) { notice = message }
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { notice = nil }
        }
    }

    func speakerName(_ id: SpeakerID?, in t: Transcript? = nil) -> String {
        guard let speaker = (t ?? transcript).speaker(id) else { return "" }
        if !speaker.name.isEmpty { return speaker.name }
        switch Channel(speaker.id) {
        case .me: return tr("Me")
        case .them: return tr("Them")
        case nil: return String(format: tr("Speaker %d"), speaker.ordinal)
        }
    }

    // MARK: Pinned question

    /// The latest question to keep above the captions, if pinning is on and the user hasn't closed it.
    var pinnedQuestion: Line? {
        guard pinsQuestions, !transcript.lines.isEmpty else { return nil }
        let hasChannels = transcript.visibleSpeakers.contains { Channel($0.id) != nil }
        guard let line = transcript.pinnedQuestion(channelsOnly: hasChannels), line.id != dismissedQuestion else { return nil }
        return line
    }

    // MARK: Live summary

    /// The summary's language, in English for the prompt. Empty setting follows the translation.
    var summaryLanguageName: String {
        let code = !summarizer.language.isEmpty ? summarizer.language
            : mode == .transcribe ? (source == "auto" ? Localizer.shared.resolved.rawValue : source)
            : mode == .twoWay ? languageB : target
        if code == "zh" { return "Simplified Chinese" }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    private func tickSummary() {
        guard summarizer.enabled, [.live, .standby, .paused].contains(status) else { return }
        summarizer.tick(transcript, languageName: summaryLanguageName, name: { [weak self] in self?.speakerName($0) ?? "" })
    }

    func refreshSummary(_ t: Transcript) {
        summarizer.refresh(t, languageName: summaryLanguageName, name: { [weak self] in self?.speakerName($0, in: t) ?? "" })
    }

    // MARK: Soniox account

    func refreshAccount() {
        let key = trimmedKey
        let org = orgKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty || !org.isEmpty else { return }
        let host = region.apiHost
        Task {
            var error: String?
            if !key.isEmpty {
                do {
                    let (data, _) = try await URLSession.shared.data(for: SonioxAccount.monthCostRequest(apiKey: key, apiHost: host))
                    accountMonthCost = try SonioxAccount.parseMonthCost(data)
                } catch let e {
                    error = e.localizedDescription
                }
            }
            if !org.isEmpty {
                do {
                    let (data, _) = try await URLSession.shared.data(for: SonioxAccount.balanceRequest(orgKey: org))
                    accountBalance = try SonioxAccount.parseBalance(data)
                } catch let e {
                    accountBalance = nil
                    error = e.localizedDescription
                }
            }
            accountError = error
            accountCheckedAt = .now
        }
    }

    // MARK: Usage

    private func resetSessionUsage() {
        flushUsage()
        sessionUsage = UsageTotals()
    }

    /// Publishes counted usage and adds it to this month's stored total.
    func flushUsage() {
        guard pendingUsage.totalMs > 0 else { return }
        let added = pendingUsage
        pendingUsage = UsageTotals()
        sessionUsage = sessionUsage + added
        let now = Date.now
        let key = UsageTotals.monthKey(now)
        // A new month starts from zero; the one just ended is already saved, so it loads as last month.
        if storedMonth != key {
            lastMonthUsage = Self.loadUsage(storedMonth)
            monthUsage = Self.loadUsage(key)
            storedMonth = key
        }
        monthUsage = monthUsage + added
        if let data = try? JSONEncoder().encode(monthUsage) { defaults.set(data, forKey: "usage.\(key)") }
    }

    /// The month `monthUsage` counts.
    @ObservationIgnored private var storedMonth = UsageTotals.monthKey(.now)

    private static func loadUsage(_ month: String) -> UsageTotals {
        guard let data = UserDefaults.standard.data(forKey: "usage.\(month)"),
              let totals = try? JSONDecoder().decode(UsageTotals.self, from: data) else { return UsageTotals() }
        return totals
    }

    // MARK: Caption visibility

    /// The user showing or hiding captions by hand.
    func setCaptions(_ visible: Bool) {
        captionsAutoHide?.cancel()
        withAnimation(.smooth) { captionsVisible = visible }
        if captionVisibility == .always {
            store(visible, "captionsVisible")
        } else {
            // Hiding mid-session sticks until the next session.
            captionsHiddenByUser = !visible && status != .idle
        }
    }

    private func followStatusWithCaptions() {
        guard captionVisibility == .whileListening else { return }
        captionsAutoHide?.cancel()
        switch status {
        case .connecting, .live, .reconnecting:
            if !captionsHiddenByUser { captionsVisible = true }
        case .error:
            captionsVisible = true
        case .paused, .standby:
            hideCaptions(after: 60, unlessStatusChanges: status)
        case .idle:
            captionsHiddenByUser = false
            // Leave the last lines up long enough to finish reading them.
            hideCaptions(after: 4, unlessStatusChanges: .idle)
        }
    }

    private func hideCaptions(after seconds: Double, unlessStatusChanges expected: Status) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.status == expected, self.captionVisibility == .whileListening else { return }
            self.captionsVisible = false
        }
        captionsAutoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func lock(_ on: Bool) {
        locked = on
        show(on ? tr("Captions locked · ⌃⌥L to unlock") : tr("Captions unlocked"))
    }

    func toggleTranscriptWindow() {
        if transcriptVisible && NSApp.isActive { closeTranscript() } else { openTranscript() }
    }

    func renameCurrentSpeaker() {
        guard let current = transcript.currentSpeaker else {
            show(tr("No one has spoken yet."))
            return
        }
        let transcriptIsKey = NSApp.keyWindow?.identifier?.rawValue.hasPrefix("transcript") == true
        NSApp.activate()
        renaming = RenameRequest(session: transcript.id, id: current, place: captionsVisible && !transcriptIsKey ? .caption : .transcript(turn: nil))
    }

    func adjustFontSize(_ delta: Double, captions: Bool, presenter: Bool = false) {
        if presenter {
            presenterFontSize = (presenterFontSize + delta * 4).clamped(to: Self.presenterFontRange)
        } else if captions {
            captionFontSize = (captionFontSize + delta * 2).clamped(to: Self.captionFontRange)
        } else {
            transcriptFontSize = (transcriptFontSize + delta).clamped(to: Self.transcriptFontRange)
        }
    }

    func adjustLines(_ delta: Int) {
        captionLines = (captionLines + delta).clamped(to: Self.captionLineRange)
    }

    var languageSummary: String {
        let locale = Localizer.shared.locale
        let name = { (code: String) in Languages.name(code, in: locale) }
        switch mode {
        case .translate: return "\(source == "auto" ? tr("Auto") : name(source)) → \(name(target))"
        case .twoWay: return "\(name(languageA)) ⇄ \(name(languageB))"
        case .threeWay: return sessionConfig.threeWayLanguages.map(name).joined(separator: " · ")
        case .transcribe: return source == "auto" ? tr("Transcribe") : name(source)
        }
    }

    func exportTranscript(_ t: Transcript? = nil) {
        guard let t = t ?? selectedTranscript else { return }
        let panel = NSSavePanel()
        let name = title(t).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        panel.nameFieldStringValue = "\(name).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = t.markdown(title: title(t), name: { self.speakerName($0, in: t) }, includeOriginal: true)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            show(error.localizedDescription)
        }
    }
}

struct RenameRequest: Identifiable, Equatable {
    enum Place: Equatable {
        case caption
        /// `nil` means the speaker's latest turn.
        case transcript(turn: Int?)
    }
    let session: UUID
    let id: SpeakerID
    let place: Place
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
