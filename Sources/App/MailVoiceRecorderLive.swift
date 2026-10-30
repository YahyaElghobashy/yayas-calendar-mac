import AVFoundation
import AppKit
import Combine

/// The voice note's microphone and playback (D-052): AVAudioRecorder writing 16 kHz mono 16-bit WAV (what whisper
/// reads) with level metering, AVAudioPlayer for listening back. Only the Draft pop-over uses it, only while the
/// person records; no audio leaves the Mac except as a file handed to Yaya's Mail Helper on Send.
@MainActor
final class MailVoiceRecorderLive: NSObject, MailVoiceRecorder, AVAudioPlayerDelegate {
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var finished: (@MainActor () -> Void)?

    var permission: Bool? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        default: return nil
        }
    }

    func requestPermission(_ done: @escaping @MainActor (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } }
        }
    }

    func start(_ url: URL) -> Bool {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        r.isMeteringEnabled = true
        guard r.prepareToRecord(), r.record() else { return false }
        recorder = r
        return true
    }

    func pause() { recorder?.pause() }
    func resume() { recorder?.record() }

    func stop() {
        recorded = recorder?.currentTime ?? recorded
        recorder?.stop()
        recorder = nil
    }

    private(set) var recorded: TimeInterval {
        get { recorder?.currentTime ?? storedTime }
        set { storedTime = newValue }
    }
    private var storedTime: TimeInterval = 0

    func level() -> Float {
        guard let r = recorder else { return 0 }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)  // -160 … 0
        return max(0, min(1, (db + 50) / 50))
    }

    func play(_ url: URL, finished: @escaping @MainActor () -> Void) -> Bool {
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return false }
        p.delegate = self
        self.finished = finished
        player = p
        return p.play()
    }

    func stopPlaying() {
        player?.stop()
        player = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { MainActor.assumeIsolated {
            self.player = nil
            self.finished?()
        } }
    }
}

extension MailHelperLive {
    /// `<data root>/voicenotes/` (0700): recordings until they are sent or discarded.
    static var voiceFolder: URL { Paths.root.appendingPathComponent("voicenotes", isDirectory: true) }

    static func installVoice() {
        MailHelperDraftModel.makeVoice = { session in
            MailVoiceNoteModel(session: session, recorder: MailVoiceRecorderLive(), env: voiceEnvironment())
        }
        removeStale(in: voiceFolder, suffix: ".wav")
    }

    static func voiceEnvironment() -> MailVoiceNoteModel.Environment {
        MailVoiceNoteModel.Environment(
            newClip: {
                guard privateFolder(voiceFolder) else { return nil }
                return voiceFolder.appendingPathComponent(UUID().uuidString.lowercased() + ".wav")
            },
            publish: { url in publishClip(url) },
            remove: { url in
                guard url.deletingLastPathComponent().standardizedFileURL == voiceFolder.standardizedFileURL else { return }
                unlink(url.path)
            },
            openPrivacy: {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(u)
                }
            },
            ticker: { tick in
                Timer.publish(every: 0.1, on: .main, in: .common).autoconnect().sink { _ in MainActor.assumeIsolated { tick() } }
            })
    }

    /// A real folder of this user's, 0700 (created if missing).
    static func privateFolder(_ url: URL) -> Bool {
        for u in [Paths.root, url] {
            if mkdir(u.path, 0o700) != 0, errno != EEXIST { return false }
            var info = stat()
            guard lstat(u.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { return false }
        }
        return chmod(url.path, 0o700) == 0
    }

    /// A copy of the recording as `share/mailhelper/voice-<uuid>.wav` (O_EXCL, O_NOFOLLOW, 0600); the helper deletes
    /// it once read, and anything it never picked up goes after an hour.
    static func publishClip(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count > 44, data.count <= 10 * 1024 * 1024 else { return nil }
        let name = MailHelperFiles.clipName(UUID())
        let temp = "." + name + ".tmp"
        guard writeShared(data, final: name, temp: temp) else { return nil }
        return name
    }
}
