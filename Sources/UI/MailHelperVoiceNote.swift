import Combine
import Foundation

// Draft with AI's voice note (D-052, contract v1.3): say what the reply should say instead of typing it. Record,
// pause, resume, stop, listen back, discard or send. Send hands the clip to Yaya's Mail Helper, which transcribes it on
// this Mac with whisper (the transcription Deck and Murmur use) and answers with text; the text goes into "What should
// it say?" and the draft starts. Nothing here touches the network. The recording lives in the app's private folder
// until it is sent or discarded; the helper gets a copy in the share folder and deletes it once read.

/// The microphone, the clip on disk and playback, behind one seam (the app gives the AVFoundation one; tests a fake).
@MainActor
protocol MailVoiceRecorder: AnyObject {
    /// nil = not asked yet; false = refused in System Settings.
    var permission: Bool? { get }
    func requestPermission(_ done: @escaping @MainActor (Bool) -> Void)
    /// 16 kHz mono 16-bit WAV at `url`; false if the microphone couldn't start.
    func start(_ url: URL) -> Bool
    func pause()
    func resume()
    func stop()
    /// Seconds recorded so far (pauses excluded).
    var recorded: TimeInterval { get }
    /// The input level now, 0…1.
    func level() -> Float
    func play(_ url: URL, finished: @escaping @MainActor () -> Void) -> Bool
    func stopPlaying()
}

@MainActor
final class MailVoiceNoteModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case asking
        case recording
        case paused
        case stopped
        case sending
        case denied
        case failed(String)
    }

    struct Environment {
        /// A fresh private file for a new recording (`…/voicenotes/<uuid>.wav`, folder 0700); nil = can't.
        var newClip: () -> URL? = { nil }
        /// Copies the clip into the share folder as `voice-<uuid>.wav` (0600) and returns that name.
        var publish: (URL) -> String? = { _ in nil }
        var remove: (URL) -> Void = { _ in }
        /// Opens System Settings → Privacy & Security → Microphone.
        var openPrivacy: () -> Void = {}
        /// Calls `tick` about ten times a second while recording or playing; the returned token stops it.
        var ticker: (@escaping @MainActor () -> Void) -> AnyCancellable = { _ in AnyCancellable {} }
    }

    /// Five minutes: plenty for "what to say", and the helper's size cap.
    static let maxDuration: TimeInterval = 300
    static let barCount = 36
    /// whisper on a five-minute clip takes well under a minute; this leaves room for a cold start.
    static let sendTimeout: TimeInterval = 150

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// The last few seconds of input level, oldest first (the bars).
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: MailVoiceNoteModel.barCount)
    @Published private(set) var playing = false

    let session: MailHelperSession
    let recorder: MailVoiceRecorder
    var env: Environment
    /// The transcript, for the pop-over (into "What should it say?", then Draft).
    var onText: @MainActor (String) -> Void
    private var clip: URL?
    private var tick: AnyCancellable?
    private var generation = 0

    init(session: MailHelperSession, recorder: MailVoiceRecorder, env: Environment, onText: @escaping @MainActor (String) -> Void = { _ in }) {
        self.session = session
        self.recorder = recorder
        self.env = env
        self.onText = onText
    }

    var isActive: Bool { phase != .idle }
    var canSend: Bool { [.recording, .paused, .stopped].contains(phase) || isFailedWithClip }
    var isFailedWithClip: Bool { if case .failed = phase { return clip != nil } else { return false } }

    /// "0:07", "1:42".
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(max(0, t.rounded(.down)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    // MARK: Recording

    func record() {
        switch recorder.permission {
        case .some(false):
            phase = .denied
        case .none:
            phase = .asking
            recorder.requestPermission { [weak self] ok in
                guard let self, self.phase == .asking else { return }
                if ok { self.begin() } else { self.phase = .denied }
            }
        case .some(true):
            begin()
        }
    }

    private func begin() {
        discardClip()
        guard let url = env.newClip(), recorder.start(url) else {
            phase = .failed("The microphone didn\u{2019}t start. Is another app using it?")
            return
        }
        clip = url
        elapsed = 0
        levels = Array(repeating: 0, count: Self.barCount)
        phase = .recording
        startTicking()
    }

    func pause() {
        guard phase == .recording else { return }
        recorder.pause()
        elapsed = recorder.recorded
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        recorder.resume()
        phase = .recording
        startTicking()
    }

    func stop() {
        guard phase == .recording || phase == .paused else { return }
        recorder.stop()
        elapsed = recorder.recorded
        tick = nil
        phase = elapsed >= 0.5 ? .stopped : .idle
        if phase == .idle { discardClip() }
    }

    /// Ten times a second: the time, the bars, and the five-minute stop.
    func tickNow() {
        if playing { return }
        guard phase == .recording else { tick = nil; return }
        elapsed = recorder.recorded
        levels = Array((levels + [max(0, min(1, recorder.level()))]).suffix(Self.barCount))
        if elapsed >= Self.maxDuration { stop() }
    }

    private func startTicking() {
        tick = env.ticker { [weak self] in self?.tickNow() }
    }

    // MARK: Listening back, discarding

    func togglePlay() {
        guard phase == .stopped || isFailedWithClip, let clip else { return }
        if playing {
            recorder.stopPlaying()
            playing = false
            return
        }
        playing = recorder.play(clip) { [weak self] in self?.playing = false }
    }

    func discard() {
        if phase == .recording || phase == .paused { recorder.stop() }
        if playing { recorder.stopPlaying(); playing = false }
        generation += 1
        tick = nil
        discardClip()
        elapsed = 0
        levels = Array(repeating: 0, count: Self.barCount)
        phase = .idle
    }

    private func discardClip() {
        if let clip { env.remove(clip) }
        clip = nil
    }

    // MARK: Sending

    /// Stops if needed, hands a copy of the clip to the helper, and on its answer passes the text on. The recording
    /// stays until the text arrives, so a failed send can be tried again or listened to.
    func send() {
        if phase == .recording || phase == .paused { stop() }
        guard let clip, phase == .stopped || isFailedWithClip else { return }
        if playing { recorder.stopPlaying(); playing = false }
        guard let name = env.publish(clip) else {
            phase = .failed("I couldn\u{2019}t hand the voice note to Yaya\u{2019}s Mail Helper.")
            return
        }
        generation += 1
        let mine = generation
        phase = .sending
        session.send(.transcribe(clip: name), timeout: Self.sendTimeout) { [weak self] r in
            guard let self, self.generation == mine else { return }
            if r.ok, let text = r.data["text"]?.string.flatMap({ MailHelperPlain.clean($0, 4000) }), !text.isEmpty {
                self.discardClip()
                self.elapsed = 0
                self.phase = .idle
                self.onText(text)
            } else {
                self.phase = .failed(r.ok ? "I couldn\u{2019}t hear any words in that voice note." : (r.error ?? "The voice note didn\u{2019}t go through."))
            }
        }
    }

    func openPrivacy() { env.openPrivacy() }
}

/// A recorder with no microphone, for tests and renders: it "records" by the clock it is given and writes a tiny WAV.
@MainActor
final class MailVoiceScriptedRecorder: MailVoiceRecorder {
    var permission: Bool?
    var grant = true
    var startOK = true
    var nextLevel: Float = 0.5
    var recorded: TimeInterval = 0
    private(set) var calls: [String] = []
    private(set) var playingURL: URL?
    private var finish: (@MainActor () -> Void)?

    init(permission: Bool? = true) { self.permission = permission }

    func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
        calls.append("ask")
        permission = grant
        done(grant)
    }

    func start(_ url: URL) -> Bool {
        calls.append("start")
        guard startOK else { return false }
        var wav = Data("RIFF".utf8); wav.append(Data(repeating: 0, count: 4)); wav.append(Data("WAVEfmt ".utf8))
        wav.append(Data(repeating: 0, count: 64))
        try? wav.write(to: url)
        recorded = 0
        return true
    }

    func pause() { calls.append("pause") }
    func resume() { calls.append("resume") }
    func stop() { calls.append("stop") }
    func level() -> Float { nextLevel }

    func play(_ url: URL, finished: @escaping @MainActor () -> Void) -> Bool {
        calls.append("play")
        playingURL = url
        finish = finished
        return true
    }

    func stopPlaying() { calls.append("stopPlaying"); playingURL = nil }
    func endPlayback() { playingURL = nil; finish?() }
}
