import AVFoundation
import MediaPlayer
import Observation

/// Pauses and resumes whatever audio another app is playing — Spotify, Apple Music,
/// podcasts — without any per-app API.
///
/// iOS gives third-party apps no way to send play/pause to another app. What it does
/// give them is the audio session: activating a non-mixable session interrupts every
/// other app's audio, and deactivating it with `.notifyOthersOnDeactivation` tells the
/// interrupted app it may resume. Players that handle interruptions properly (Spotify,
/// Music, Podcasts and most others) pause and resume on cue.
///
/// The limit is that this can only resume audio it paused itself. Starting music from
/// silence falls back to Apple Music, the one player with a public control API, and
/// only when it has something queued.
@Observable
final class MusicControl {
    private(set) var isPlaying = false

    @ObservationIgnored private let session = AVAudioSession.sharedInstance()
    @ObservationIgnored private let appleMusic = MPMusicPlayerController.systemMusicPlayer
    /// True while our session is holding another app's audio paused.
    @ObservationIgnored private var holdingOthersPaused = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        // Posted when another app's audio starts or stops while we're in the foreground.
        observers.append(center.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: session, queue: .main
        ) { [weak self] _ in self?.refresh() })
        // Another app activating its session (e.g. Spotify resumed from Control Center)
        // interrupts ours, which means we're no longer holding anything paused.
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            holdingOthersPaused = false
            refresh()
        })
        refresh()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if holdingOthersPaused { resumeOthers() }
    }

    /// Picks up changes made outside the app (Control Center, headphones).
    func refresh() {
        isPlaying = session.isOtherAudioPlaying
    }

    func toggle() {
        if session.isOtherAudioPlaying {
            pauseOthers()
        } else if holdingOthersPaused {
            resumeOthers()
        } else {
            playAppleMusic()
        }
    }

    private func pauseOthers() {
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            holdingOthersPaused = true
            isPlaying = false
        } catch {
            refresh()
        }
    }

    private func resumeOthers() {
        holdingOthersPaused = false
        // Lets the interrupted app see `.shouldResume`; it restarts itself shortly after.
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        isPlaying = true
    }

    private func playAppleMusic() {
        MPMediaLibrary.requestAuthorization { status in
            guard status == .authorized else { return }
            DispatchQueue.main.async { [self] in
                // With nothing queued, `play()` would do nothing, or start something unwanted.
                guard appleMusic.nowPlayingItem != nil else { return }
                appleMusic.play()
                isPlaying = true
            }
        }
    }
}

@Observable
final class Flashlight {
    private(set) var isOn = false

    var isAvailable: Bool { AVCaptureDevice.default(for: .video)?.hasTorch ?? false }

    func toggle() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if isOn {
                device.torchMode = .off
            } else {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            }
            isOn.toggle()
        } catch {
            isOn = device.torchMode == .on
        }
    }
}
