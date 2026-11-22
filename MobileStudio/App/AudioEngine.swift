import AVFoundation
import Combine
import StudioCore

/// Sound playback for Play mode and Toolbox audio previews (port of audio/AudioEngine.kt).
final class AudioEngine: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum PreviewState: Equatable { case loading, playing, paused, error }

    struct Preview: Equatable {
        let id: Int64
        var state: PreviewState
        var position: Float = 0
        var length: Float = 0
        var error: String? = nil
    }

    @Published private(set) var preview: Preview?

    private var players: [ObjectIdentifier: AVAudioPlayer] = [:]
    private var previewPlayer: AVAudioPlayer?
    private var previewTimer: Timer?
    private var previewGen = 0

    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
    }

    // MARK: Play mode sounds

    func set(_ sound: Instance, playing: Bool) {
        let key = ObjectIdentifier(sound)
        guard playing else { players[key]?.stop(); players[key] = nil; return }
        guard let url = AssetCache.shared.localURL(for: sound.get("SoundId")?.description ?? "") else {
            AssetCache.shared.fetch(sound.get("SoundId")?.description ?? "") { [weak self, weak sound] url in
                guard let self, let sound, url != nil, sound.get("Playing")?.asBool == true else { return }
                self.set(sound, playing: true)
            }
            return
        }
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.volume = min(1, max(0, sound.get("Volume")?.asFloat ?? 0.5))
        p.enableRate = true
        p.rate = sound.get("PlaybackSpeed")?.asFloat ?? 1
        p.numberOfLoops = sound.get("Looped")?.asBool == true ? -1 : 0
        p.play()
        players[key] = p
    }

    func stopAll() {
        for p in players.values { p.stop() }
        players.removeAll()
        stopPreview()
    }

    // MARK: AudioBrowser preview

    func togglePreview(id: Int64) {
        if let cur = preview, cur.id == id {
            if cur.state == .playing, let p = previewPlayer {
                p.pause()
                preview?.state = .paused
                previewTimer?.invalidate()
                previewTimer = nil
                return
            }
            if cur.state == .paused, let p = previewPlayer {
                try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
                p.play()
                preview?.state = .playing
                startPreviewTimer()
                return
            }
            if cur.state == .loading {
                stopPreview()
                return
            }
        }
        stopPreview()
        previewGen += 1
        let gen = previewGen
        preview = Preview(id: id, state: .loading)
        AssetCache.shared.fetch("rbxassetid://\(id)") { [weak self] url in
            guard let self, self.previewGen == gen else { return }
            guard let url else {
                let err = AssetCache.shared.lastError[id]
                    ?? (AccountStore.shared.isSignedIn ? "Couldn't download this audio" : "Sign in to Roblox to preview audio")
                self.preview = Preview(id: id, state: .error, error: err)
                return
            }
            do {
                try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                p.prepareToPlay()
                p.play()
                self.previewPlayer = p
                self.preview = Preview(id: id, state: .playing, position: 0, length: Float(p.duration))
                self.startPreviewTimer()
            } catch {
                self.preview = Preview(id: id, state: .error, error: "Unsupported audio format on iOS")
            }
        }
    }

    func seekPreview(id: Int64, seconds: Float) {
        guard let cur = preview, cur.id == id, let p = previewPlayer else { return }
        let clamped = max(0, min(Float(p.duration), seconds))
        p.currentTime = TimeInterval(clamped)
        preview?.position = clamped
    }

    func stopPreview() {
        previewGen += 1
        previewTimer?.invalidate()
        previewTimer = nil
        previewPlayer?.stop()
        previewPlayer = nil
        preview = nil
    }

    private func startPreviewTimer() {
        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let p = self.previewPlayer, self.preview != nil else { return }
            self.preview?.position = Float(p.currentTime)
            if !p.isPlaying && self.preview?.state == .playing {
                self.preview?.state = .paused
                self.previewTimer?.invalidate()
                self.previewTimer = nil
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if player === previewPlayer {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.preview?.state = .paused
                self.preview?.position = 0
                self.previewTimer?.invalidate()
                self.previewTimer = nil
            }
        }
    }
}
