import AVFoundation
import StudioCore

/// Sound playback for Play mode (port of audio/AudioEngine.kt). Plays sounds whose audio is
/// available locally (asset cache); other sounds are tracked as playing but silent.
final class AudioEngine {
    private var players: [ObjectIdentifier: AVAudioPlayer] = [:]

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
    }

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
    }
}
