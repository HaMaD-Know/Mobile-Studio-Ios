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
    public static func fromInstance(_ inst: Instance) -> AnimClip? {
        switch inst.className {
        case "KeyframeSequence": return from(inst)
        case "CurveAnimation": return CurveAnim.from(inst)
        default: return nil
        }
    }
}

/// Loads animation assets once and caches the clips (port of engine/AnimLibrary.kt).
public final class AnimLibrary {
    private var clips: [Int64: AnimClip] = [:]
    private var failed = Set<Int64>()
    private var pending = Set<Int64>()
    /// Asset loader provided by the app: content id -> file bytes (async).
    public var loader: ((String, @escaping (Data?) -> Void) -> Void)?

    public init() {}

    static func assetId(_ s: String) -> Int64? {
        if s.hasPrefix("rbxassetid://") { return Int64(s.dropFirst(13).prefix { $0.isNumber }) }
        if let r = s.range(of: "id=") { return Int64(s[r.upperBound...].prefix { $0.isNumber }) }
        return Int64(s)
    }

    func clip(_ content: String) -> AnimClip? {
        if content.hasPrefix("rbxtemp://") || content.hasPrefix("active://") {
            return EditAnimation.shared.clip(for: content)
        }
        guard let id = AnimLibrary.assetId(content) else { return nil }
        if let c = clips[id] { return c }
        guard !failed.contains(id), !pending.contains(id), let loader else { return nil }
        pending.insert(id)
        loader("rbxassetid://\(id)") { [weak self] data in
            guard let self else { return }
            self.pending.remove(id)
            guard let data, let doc = try? RbxFile.read(data),
                  let seq = doc.roots.flatMap({ [$0] + $0.descendants() }).first(where: { $0.className == "KeyframeSequence" || $0.className == "CurveAnimation" }),
                  let clip = AnimClip.fromInstance(seq) else { self.failed.insert(id); return }
            self.clips[id] = clip
        }
        return nil
    }

    func failed(_ content: String) -> Bool {
        if content.hasPrefix("rbxtemp://") || content.hasPrefix("active://") { return EditAnimation.shared.clip(for: content) == nil }
        return AnimLibrary.assetId(content).map { failed.contains($0) } ?? true
    }
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

/// Roblox's default character animations & builtin `Animate` LocalScript tree
/// (port of engine/DefaultAnimate.kt).
public enum DefaultAnimate {
    public struct Entry { public let id: String; public let weight: Float }

    public static let emoteNames: [(title: String, key: String)] = [
        ("Wave", "wave"), ("Point", "point"), ("Cheer", "cheer"), ("Laugh", "laugh"),
        ("Dance", "dance"), ("Dance 2", "dance2"), ("Dance 3", "dance3"),
    ]
    public static let loopingEmotes: Set<String> = ["dance", "dance2", "dance3"]

    static let r15Tree: [String: [(String, Int64, Float)]] = [
        "idle": [("Animation1", 507766666, 9), ("Animation2", 507766951, 1)],
        "walk": [("WalkAnim", 507777826, 10)],
        "run": [("RunAnim", 507767714, 10)],
        "jump": [("JumpAnim", 507765000, 10)],
        "fall": [("FallAnim", 507767968, 10)],
        "climb": [("ClimbAnim", 507765644, 10)],
        "swim": [("Swim", 507784897, 10)],
        "swimidle": [("SwimIdle", 507785072, 10)],
        "sit": [("SitAnim", 2506281703, 10)],
        "toolnone": [("ToolNoneAnim", 507768375, 10)],
        "wave": [("WaveAnim", 507770239, 10)],
        "point": [("PointAnim", 507770453, 10)],
        "dance": [("Animation1", 507771019, 10), ("Animation2", 507771955, 10), ("Animation3", 507772104, 10)],
        "dance2": [("Animation1", 507776043, 10), ("Animation2", 507776720, 10), ("Animation3", 507776879, 10)],
        "dance3": [("Animation1", 507777268, 10), ("Animation2", 507777451, 10), ("Animation3", 507777623, 10)],
        "laugh": [("LaughAnim", 507770818, 10)],
        "cheer": [("CheerAnim", 507770677, 10)],
    ]

    static let r6Tree: [String: [(String, Int64, Float)]] = [
        "idle": [("Animation1", 180435571, 9), ("Animation2", 180435792, 1)],
        "walk": [("WalkAnim", 180426354, 10)],
        "run": [("RunAnim", 180426354, 10)],
        "jump": [("JumpAnim", 125750702, 10)],
        "fall": [("FallAnim", 180436148, 10)],
        "climb": [("ClimbAnim", 180436334, 10)],
        "sit": [("SitAnim", 178130996, 10)],
        "toolnone": [("ToolNoneAnim", 182393478, 10)],
        "wave": [("WaveAnim", 128777973, 10)],
        "point": [("PointAnim", 128853357, 10)],
        "dance": [("Animation1", 182435998, 10), ("Animation2", 182491037, 10), ("Animation3", 182491065, 10)],
        "dance2": [("Animation1", 182436842, 10), ("Animation2", 182491248, 10), ("Animation3", 182491277, 10)],
        "dance3": [("Animation1", 182436935, 10), ("Animation2", 182491368, 10), ("Animation3", 182491423, 10)],
        "laugh": [("LaughAnim", 129423131, 10)],
        "cheer": [("CheerAnim", 129423030, 10)],
    ]

    /// Attaches Roblox's default `Animate` LocalScript + StringValue/Animation config tree to `char`
    /// unless the place already supplied an `Animate` child (e.g. via StarterCharacterScripts).
    @discardableResult
    public static func attach(to char: Instance, r15: Bool) -> Instance? {
        if char.findFirstChild("Animate") != nil { return nil }
        let script = InstanceFactory.create("LocalScript")
        script.name = "Animate"
        script.archivable = false
        script.attributes["__builtinAnimate"] = .bool(true)
        script.set("Source", .string("-- Default character animations (managed by Mobile Studio)\n"), notify: false)
        let tree = r15 ? r15Tree : r6Tree
        for (pose, list) in tree {
            let sv = InstanceFactory.create("StringValue")
            sv.name = pose
            sv.attachRaw(script)
            for (animName, id, weight) in list {
                let a = InstanceFactory.create("Animation")
                a.name = animName
                a.set("AnimationId", .string("rbxassetid://\(id)"), notify: false)
                a.attachRaw(sv)
                let w = InstanceFactory.create("NumberValue")
                w.name = "Weight"
                w.set("Value", .double(Double(weight)), notify: false)
                w.attachRaw(a)
            }
        }
        script.attachRaw(char)
        return script
    }

    /// Reads the character's builtin `Animate` config; returns `nil` when `Animate` was removed,
    /// disabled, or replaced with a user script.
    public static func config(of char: Instance) -> [String: [Entry]]? {
        guard let script = char.findFirstChild("Animate"),
              script.attributes["__builtinAnimate"]?.asBool == true,
              script.get("Disabled")?.asBool != true else { return nil }
        var out: [String: [Entry]] = [:]
        for child in script.children where child.className == "StringValue" {
            var entries: [Entry] = []
            for a in child.children where a.className == "Animation" {
                let id = a.get("AnimationId")?.description ?? ""
                guard !id.isEmpty else { continue }
                let w = a.findFirstChild("Weight")?.get("Value")?.asFloat ?? 10
                entries.append(Entry(id: id, weight: max(0.01, w)))
            }
            if !entries.isEmpty { out[child.name] = entries }
        }
        return out
    }

    /// Weighted random choice among entries for a pose.
    public static func pick(_ entries: [Entry]?) -> String? {
        guard let entries, !entries.isEmpty else { return nil }
        if entries.count == 1 { return entries[0].id }
        let total = entries.reduce(Float(0)) { $0 + $1.weight }
        var r = Float.random(in: 0..<max(total, 0.001))
        for e in entries {
            r -= e.weight
            if r <= 0 { return e.id }
        }
        return entries.last?.id
    }
}

/// Legacy alias kept for tests/callers.
enum DefaultAnimations {
    static let r15: [String: [Int64]] = DefaultAnimate.r15Tree.mapValues { $0.map(\.1) }
    static let r6: [String: [Int64]] = DefaultAnimate.r6Tree.mapValues { $0.map(\.1) }
}
