import AVFoundation
import MediaPlayer
import Observation

/// Plays and pauses the system Music app. iOS doesn't let third-party apps control
/// other players (Spotify etc.), so this only drives Apple Music / the Music library.
@Observable
final class MusicControl {
    private(set) var isPlaying = false

    @ObservationIgnored private let player = MPMusicPlayerController.systemMusicPlayer

    init() {
        refresh()
    }

    /// Picks up changes made outside the app (Control Center, headphones).
    func refresh() {
        isPlaying = player.playbackState == .playing
    }

    func toggle() {
        MPMediaLibrary.requestAuthorization { status in
            guard status == .authorized else { return }
            DispatchQueue.main.async { [self] in
                refresh()
                if isPlaying {
                    player.pause()
                } else {
                    player.play()
                }
                isPlaying.toggle()
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
