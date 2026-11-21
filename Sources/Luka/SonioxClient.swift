import Foundation
import LukaCore

@MainActor
final class SonioxClient {
    enum Event {
        case connected
        /// `baseMs` is where this stream's audio began on the shared audio clock.
        case response(SonioxResponse, baseMs: Int)
        case failed(SonioxError)
        /// The socket dropped; the client is opening a replacement stream.
        case reconnecting(attempt: Int)
    }

    enum SonioxError: Error, Equatable {
        case invalidKey, noCredits, rateLimited, config(String), network(String)
    }

    private static let maxReconnects = 5

    var onEvent: (Event) -> Void = { _ in }
    var carryover: () -> String? = { nil }
    /// Milliseconds of audio sent so far, shared by every stream so their token times line up.
    var clock: () -> Int = { 0 }
    let lane: Int

    private var baseMs = 0

    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var config: SessionConfig?
    private var apiKey = ""
    private var endpoint = SonioxRegion.us.websocketURL
    private var attempts = 0
    private var lastAudio = Date.distantPast
    private var keepalive: Timer?
    /// Waiting to open a replacement stream after a drop.
    private var reconnecting = false
    /// Audio no stream has taken yet: what came in while reconnecting, and since, until the new stream
    /// is up. Sent first on each stream that is opened, so a retry that fails too loses nothing.
    private var pending: [Data] = []
    private var pendingBytes = 0
    /// 16 kHz, 16-bit mono.
    private static let bytesPerMs = 32
    /// Half a minute: longer than every retry takes together. Past it, the oldest audio goes.
    private static let maxPendingBytes = bytesPerMs * 30_000
    /// The stream now open has accepted its settings, so audio sent to it needs no keeping.
    private var confirmed = false

    var isOpen: Bool { task != nil }

    init(lane: Int = 0) {
        self.lane = lane
    }

    func connect(apiKey: String, region: SonioxRegion, config: SessionConfig) {
        self.apiKey = apiKey
        endpoint = region.websocketURL
        self.config = config
        attempts = 0
        open(carryover: carryover())
    }

    private func open(carryover: String?) {
        guard let config else { return }
        closeSocket()
        let gen = generation
        let task = URLSession.shared.webSocketTask(with: endpoint)
        self.task = task
        // Audio held back during a reconnect began that much earlier on the clock.
        baseMs = clock() - pendingBytes / Self.bytesPerMs
        reconnecting = false
        confirmed = false
        task.resume()
        task.send(.string(config.json(apiKey: apiKey, carryover: carryover, lane: lane))) { [weak self] error in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if let error {
                    self.dropped(error)
                } else {
                    self.confirmed = true
                    self.dropPending()
                    self.onEvent(.connected)
                }
            }
        }
        for audio in pending { task.send(.data(audio)) { _ in } }
        receive(task, gen: gen)
        keepalive = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendKeepaliveIfIdle() }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, gen: Int) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(text)
                    if gen == self.generation { self.receive(task, gen: gen) }
                case .success:
                    self.receive(task, gen: gen)
                case .failure(let error):
                    self.dropped(error)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let response = try? SonioxResponse.decode(text) else { return }
        if let code = response.errorCode {
            let message = response.errorMessage ?? ""
            switch code {
            case 401: fail(.invalidKey)
            case 402: fail(.noCredits)
            case 429: fail(.rateLimited)
            case 400: fail(.config(message))
            default: dropped(NSError(domain: "Soniox", code: code, userInfo: [NSLocalizedDescriptionKey: message]))
            }
            return
        }
        attempts = 0
        onEvent(.response(response, baseMs: baseMs))
        if response.finished { closeSocket() }
    }

    private func dropped(_ error: Error) {
        guard config != nil else { return }
        if attempts >= Self.maxReconnects {
            fail(.network(error.localizedDescription))
            return
        }
        attempts += 1
        closeSocket()
        reconnecting = true
        onEvent(.reconnecting(attempt: attempts))
        let delay = min(8.0, pow(2.0, Double(attempts - 1)))
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation, self.config != nil else { return }
            self.open(carryover: self.carryover())
        }
    }

    private func dropPending() {
        pending.removeAll()
        pendingBytes = 0
    }

    private func fail(_ error: SonioxError) {
        config = nil
        reconnecting = false
        dropPending()
        closeSocket()
        onEvent(.failed(error))
    }

    /// Whether the audio was taken: sent, or held for the stream being reopened.
    @discardableResult
    func send(audio: Data) -> Bool {
        guard let task else {
            guard reconnecting else { return false }
            hold(audio)
            return true
        }
        // Until the stream is up it may still fail: keep a copy for the next one.
        if !confirmed { hold(audio) }
        lastAudio = .now
        task.send(.data(audio)) { _ in }
        return true
    }

    private func hold(_ audio: Data) {
        pending.append(audio)
        pendingBytes += audio.count
        while pendingBytes > Self.maxPendingBytes, let oldest = pending.first {
            pendingBytes -= oldest.count
            pending.removeFirst()
        }
    }

    /// Flush pending words as final without ending the stream.
    func finalize() {
        task?.send(.string(#"{"type":"finalize"}"#)) { _ in }
    }

    private func sendKeepaliveIfIdle() {
        guard let task, Date.now.timeIntervalSince(lastAudio) > 4 else { return }
        task.send(.string(#"{"type":"keepalive"}"#)) { _ in }
    }

    /// Also ends a reconnect that is waiting to happen.
    func disconnect() {
        config = nil
        reconnecting = false
        dropPending()
        if let task {
            task.send(.string("")) { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { task.cancel(with: .normalClosure, reason: nil) }
        }
        generation += 1
        task = nil
        keepalive?.invalidate()
        keepalive = nil
    }

    private func closeSocket() {
        generation += 1
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        keepalive?.invalidate()
        keepalive = nil
    }
}

/// The Soniox streams one session needs: one normally, one per language in three-way mode.
/// Every stream hears the same audio; lane 0 carries the transcript.
/// In Me / Them mode there are two streams on different audio: lane 0 hears the Mac (them),
/// lane 1 the microphone (me), and each carries its own transcript.
@MainActor
final class SonioxStreams {
    private static let maxLanes = 3
    private let clients: [SonioxClient]
    private var active = 1
    private var sentMs = 0
    /// Me / Them mode: lanes hear different audio.
    private(set) var split = false
    /// Whether each lane returns translations, for the usage estimate.
    private var translates: [Bool] = []

    var onEvent: (_ lane: Int, SonioxClient.Event) -> Void = { _, _ in }
    /// Audio handed to an open stream, in ms, and whether that stream translates. Soniox bills per stream.
    var onUsage: (_ ms: Int, _ translated: Bool) -> Void = { _, _ in }
    var carryover: () -> String? = { nil } {
        didSet { clients.forEach { $0.carryover = carryover } }
    }

    init() {
        clients = (0..<Self.maxLanes).map { SonioxClient(lane: $0) }
        for client in clients {
            client.onEvent = { [weak self] in self?.onEvent(client.lane, $0) }
            client.clock = { [weak self] in self?.sentMs ?? 0 }
        }
    }

    var isOpen: Bool { clients[0].isOpen }

    /// `myVoice` opens Me / Them mode: `config` for the Mac audio, `myVoice` for the microphone.
    func connect(apiKey: String, region: SonioxRegion, config: SessionConfig, myVoice: SessionConfig? = nil) {
        disconnect()
        if let myVoice {
            split = true
            active = 2
            translates = [config.translates, myVoice.translates]
            clients[0].connect(apiKey: apiKey, region: region, config: config)
            clients[1].connect(apiKey: apiKey, region: region, config: myVoice)
            return
        }
        split = false
        active = min(config.lanes, Self.maxLanes)
        translates = Array(repeating: config.translates, count: active)
        for client in clients.prefix(active) { client.connect(apiKey: apiKey, region: region, config: config) }
    }

    /// `lane` sends to one stream only, in Me / Them mode; otherwise every stream hears the audio.
    func send(audio: Data, lane: Int? = nil) {
        let ms = audio.count / 32
        if split, let lane, clients.indices.contains(lane) {
            // The Mac audio keeps the clock; both sources run in real time, so they stay in step.
            if lane == 0 { sentMs += ms }
            send(audio, ms: ms, to: clients[lane])
            return
        }
        // The clock runs whether or not a stream is open, so a stream that reconnects stays aligned.
        sentMs += ms
        for client in clients.prefix(active) { send(audio, ms: ms, to: client) }
    }

    private func send(_ audio: Data, ms: Int, to client: SonioxClient) {
        guard client.send(audio: audio) else { return }
        onUsage(ms, translates.indices.contains(client.lane) ? translates[client.lane] : true)
    }

    func finalize() {
        for client in clients.prefix(active) { client.finalize() }
    }

    /// Every stream, open or not: one waiting to reconnect would otherwise open again later and stay open.
    func disconnect() {
        for client in clients { client.disconnect() }
    }
}
