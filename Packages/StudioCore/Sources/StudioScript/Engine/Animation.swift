import Foundation
import StudioCore

/// A KeyframeSequence turned into per-joint keys (port of engine/AnimClip.kt).
public final class AnimClip {
    struct Key { let t: Float; let cf: CFrame; let style: Int; let dir: Int }
    let length: Float
    let looped: Bool
    let priority: Int
    let joints: [String: [Key]]

    init(length: Float, looped: Bool, priority: Int, joints: [String: [Key]]) {
        self.length = length; self.looped = looped; self.priority = priority; self.joints = joints
    }

    /// Joint transform at time t (nil if the clip doesn't animate this joint).
    func sample(_ joint: String, _ t: Float) -> CFrame? {
        guard let keys = joints[joint], let first = keys.first else { return nil }
        if keys.count == 1 || t <= first.t { return first.cf }
        let last = keys[keys.count - 1]
        if t >= last.t { return last.cf }
        var i = 0
        while i < keys.count - 2 && keys[i + 1].t <= t { i += 1 }
        let a = keys[i], b = keys[i + 1]
        let span = b.t - a.t
        return span <= 1e-5 ? b.cf : a.cf.lerp(b.cf, AnimClip.ease((t - a.t) / span, a.style, a.dir))
    }

    /// Enum.PoseEasingStyle: Linear 0, Constant 1, Elastic 2, Cubic 3, Bounce 4, CubicV2 5.
    static func ease(_ x: Float, _ style: Int, _ dir0: Int) -> Float {
        if style == 0 { return x }
        if style == 1 { return 0 }
        let dir = (style == 5 || dir0 == 2) ? dir0 : 1 - dir0
        func inF(_ t: Float) -> Float {
            switch style {
            case 2: return t <= 0 || t >= 1 ? t : -Float(pow(2, Double((t - 1) * 10))) * sin((t - 1.075) * 6.2831855 / 0.3)
            case 4: return 1 - Easing.bounceOut(1 - t)
            default: return t * t * t
            }
        }
        switch dir {
        case 0: return inF(x)
        case 1: return 1 - inF(1 - x)
        default: return x < 0.5 ? inF(x * 2) / 2 : 1 - inF((1 - x) * 2) / 2
        }
    }

    public static func from(_ seq: Instance) -> AnimClip? {
        guard seq.className == "KeyframeSequence" else { return nil }
        var lists: [String: [Key]] = [:]
        var length: Float = 0
        func walk(_ t: Float, _ p: Instance) {
            for c in p.children where c.className == "Pose" {
                let w = c.get("Weight")?.asFloat ?? 1
                if w > 0 {
                    let cf = c.get("CFrame")?.asCFrame ?? .identity
                    lists[c.name, default: []].append(Key(t: t, cf: cf, style: Int(c.get("EasingStyle")?.asEnum ?? 0),
                                                          dir: Int(c.get("EasingDirection")?.asEnum ?? 0)))
                }
                walk(t, c)
            }
        }
        for kf in seq.children where kf.className == "Keyframe" {
            let t = kf.get("Time")?.asFloat ?? 0
            length = max(length, t)
            walk(t, kf)
        }
        guard !lists.isEmpty else { return nil }
        return AnimClip(length: length, looped: seq.get("Loop")?.asBool ?? false, priority: Int(seq.get("Priority")?.asEnum ?? 0),
                        joints: lists.mapValues { $0.sorted { $0.t < $1.t } })
    }
}

/// Loads animation assets once and caches the clips (port of engine/AnimLibrary.kt).
public final class AnimLibrary {
    private var clips: [Int64: AnimClip] = [:]
    private var failed = Set<Int64>()
    private var pending = Set<Int64>()
    /// Asset loader provided by the app: content id -> file bytes (async).
    var loader: ((String, @escaping (Data?) -> Void) -> Void)?

    static func assetId(_ s: String) -> Int64? {
        if s.hasPrefix("rbxassetid://") { return Int64(s.dropFirst(13).prefix { $0.isNumber }) }
        if let r = s.range(of: "id=") { return Int64(s[r.upperBound...].prefix { $0.isNumber }) }
        return Int64(s)
    }

    func clip(_ content: String) -> AnimClip? {
        guard let id = AnimLibrary.assetId(content) else { return nil }
        if let c = clips[id] { return c }
        guard !failed.contains(id), !pending.contains(id), let loader else { return nil }
        pending.insert(id)
        loader("rbxassetid://\(id)") { [weak self] data in
            guard let self else { return }
            self.pending.remove(id)
            guard let data, let doc = try? RbxFile.read(data),
                  let seq = doc.roots.flatMap({ [$0] + $0.descendants() }).first(where: { $0.className == "KeyframeSequence" }),
                  let clip = AnimClip.from(seq) else { self.failed.insert(id); return }
            self.clips[id] = clip
        }
        return nil
    }

    func failed(_ content: String) -> Bool { AnimLibrary.assetId(content).map { failed.contains($0) } ?? true }
}

/// Blends playing clips into joint transforms (port of engine/AnimPlayer.kt).
final class AnimPlayer {
    final class Track {
        let clip: AnimClip
        let tag: String
        var time: Float = 0
        var weight: Float = 0
        var targetWeight: Float
        var fadeRate: Float
        var speed: Float
        let priority: Int
        var stopping = false
        var looped: Bool
        weak var ref: AnimTrackRef?
        init(clip: AnimClip, tag: String, fade: Float, weight: Float, speed: Float, priority: Int) {
            self.clip = clip; self.tag = tag; targetWeight = weight; self.speed = speed; self.priority = priority
            fadeRate = fade > 0 ? weight / fade : 1000
            looped = clip.looped
        }
    }
    private(set) var tracks: [Track] = []

    @discardableResult
    func play(_ clip: AnimClip, tag: String, fade: Float, weight: Float = 1, speed: Float = 1, priority: Int? = nil) -> Track {
        let t = Track(clip: clip, tag: tag, fade: fade, weight: weight, speed: speed, priority: priority ?? clip.priority)
        tracks.append(t)
        return t
    }
    func stop(_ t: Track, fade: Float) {
        t.stopping = true
        t.targetWeight = 0
        t.fadeRate = fade > 0 ? max(t.weight, 0.01) / fade : 1000
    }
    func stopTag(_ tag: String, fade: Float) { for t in tracks where t.tag == tag && !t.stopping { stop(t, fade: fade) } }
    func isPlaying(_ tag: String) -> Bool { tracks.contains { $0.tag == tag && !$0.stopping } }

    /// Advance; returns tracks that finished this step.
    func step(_ dt: Float) -> [Track] {
        var done: [Track] = []
        for t in tracks {
            t.time += dt * t.speed
            if t.time > t.clip.length {
                if t.looped && t.clip.length > 0 { t.time = t.time.truncatingRemainder(dividingBy: t.clip.length) }
                else if !t.stopping { stop(t, fade: 0.1); done.append(t) }
            }
            if t.weight < t.targetWeight { t.weight = min(t.targetWeight, t.weight + t.fadeRate * dt) }
            else if t.weight > t.targetWeight { t.weight = max(t.targetWeight, t.weight - t.fadeRate * dt) }
        }
        tracks.removeAll { $0.stopping && $0.weight <= 0.001 }
        return done
    }

    /// Weighted transform for a joint: the highest-priority tracks win, lower ones fill in.
    func transform(_ joint: String) -> CFrame? {
        let active = tracks.filter { $0.weight > 0.001 && $0.clip.joints[joint] != nil }
        guard let topPriority = active.map(\.priority).max() else { return nil }
        var result: CFrame?
        var total: Float = 0
        for t in active where t.priority == topPriority {
            guard let cf = t.clip.sample(joint, min(t.time, t.clip.length)) else { continue }
            total += t.weight
            result = result.map { $0.lerp(cf, t.weight / total) } ?? CFrame.identity.lerp(cf, min(1, t.weight))
        }
        return result
    }

    func clear() { tracks.removeAll() }
}

/// Roblox's default character animations (port of engine/DefaultAnimate.kt).
enum DefaultAnimations {
    static let r15: [String: [Int64]] = [
        "idle": [507766666, 507766951], "walk": [913402848], "run": [913376220], "jump": [507765000], "fall": [507767968],
        "climb": [507765644], "sit": [2506281703], "toolnone": [507768375], "wave": [507770239], "point": [507770453],
        "dance": [507771019, 507771955, 507772104], "laugh": [507770818], "cheer": [507770677],
    ]
    static let r6: [String: [Int64]] = [
        "idle": [180435571, 180435792], "walk": [180426354], "run": [180426354], "jump": [125750702], "fall": [180436148],
        "climb": [180436334], "sit": [178130996], "toolnone": [182393478], "wave": [128777973], "point": [128853357],
        "dance": [182435998, 182491037, 182491065], "laugh": [129423131], "cheer": [129423030],
    ]
}
