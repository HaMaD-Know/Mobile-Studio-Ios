import Foundation
import StudioCore

/// A connected signal handler (port of lua/Connection.kt).
public final class Connection {
    let ownerKey: ObjectIdentifier?
    let name: String
    let fn: LuaRef
    let once: Bool
    var connected = true
    init(owner: AnyObject, name: String, fn: LuaRef, once: Bool) {
        ownerKey = ObjectIdentifier(owner); self.name = name; self.fn = fn; self.once = once
    }
}

/// An RBXScriptSignal value: an owner object plus an event name (port of lua/SignalRef.kt).
public final class SignalRef {
    let owner: AnyObject
    let name: String
    init(owner: AnyObject, name: String) { self.owner = owner; self.name = name }
}

/// TweenInfo (port of lua/TweenInfoV.kt). Style/direction use Enum.EasingStyle / EasingDirection values.
public struct TweenInfoV: Hashable {
    var time: Float = 1
    var style: Int = 3       // Quad
    var direction: Int = 1   // Out
    var repeatCount: Int = 0
    var reverses = false
    var delay: Float = 0
}

/// A running tween (port of lua/Tween.kt).
public final class Tween {
    enum State: Int { case begin = 0, delayed = 1, playing = 2, paused = 3, completed = 4, cancelled = 5 }
    let inst: Instance
    let info: TweenInfoV
    let goals: [String: ScriptValue]
    var start: [String: ScriptValue] = [:]
    var elapsed: Float = 0
    var reversing = false
    var repeatsDone = 0
    var state: State = .begin
    init(inst: Instance, info: TweenInfoV, goals: [String: ScriptValue]) { self.inst = inst; self.info = info; self.goals = goals }
}

/// Easing curves (LuaTypes.ease in the Android app).
enum Easing {
    static func ease(style: Int, direction: Int, _ t0: Float) -> Float {
        let t = min(1, max(0, t0))
        switch direction {
        case 0: return easeIn(style, t)
        case 1: return 1 - easeIn(style, 1 - t)
        default: return t < 0.5 ? easeIn(style, t * 2) / 2 : 1 - easeIn(style, (1 - t) * 2) / 2
        }
    }
    static func easeIn(_ style: Int, _ x: Float) -> Float {
        switch style {
        case 0: return x
        case 1: return 1 - cos(.pi * x / 2)
        case 2: return x * x * ((1 + 1.70158) * x - 1.70158)
        case 3: return x * x
        case 4: return x * x * x * x
        case 5: return x * x * x * x * x
        case 6: return 1 - bounceOut(1 - x)
        case 7:
            if x == 0 || x == 1 { return x }
            return -Float(pow(2, Double(x) * 10 - 10)) * sin((10 * x - 10.75) * 2.0943952)
        case 8: return x == 0 ? 0 : Float(pow(2, Double(x) * 10 - 10))
        case 9: return 1 - (1 - x * x).squareRoot()
        case 10: return x * x * x
        default: return x * x
        }
    }
    static func bounceOut(_ x: Float) -> Float {
        if x < 1 / 2.75 { return 7.5625 * x * x }
        if x < 2 / 2.75 { let y = x - 1.5 / 2.75; return 7.5625 * y * y + 0.75 }
        if x < 2.5 / 2.75 { let y = x - 2.25 / 2.75; return 7.5625 * y * y + 0.9375 }
        let y = x - 2.625 / 2.75
        return 7.5625 * y * y + 0.984375
    }
}

/// Roblox `Random` (xorshift-based, deterministic per seed).
public final class RandomGen {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    func nextU64() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    func nextNumber() -> Double { Double(nextU64() >> 11) / Double(1 << 53) }
    func nextInteger(_ a: Int, _ b: Int) -> Int {
        let lo = min(a, b), hi = max(a, b)
        return lo + Int(nextU64() % UInt64(hi - lo + 1))
    }
    func clone() -> RandomGen { let r = RandomGen(seed: 1); r.state = state; return r }
}

/// RaycastParams (port of lua/RaycastParamsV.kt). FilterType: 0 = Exclude (Blacklist), 1 = Include (Whitelist).
public final class RaycastParamsV {
    public var filter: [Instance] = []
    public var filterType = 0
    public var ignoreWater = false
    public var collisionGroup = "Default"
    public var respectCanCollide = false
    public var bruteForceAllSlow = false
    public init() {}

    /// Whether `part` passes the filter.
    public func accepts(_ part: Instance) -> Bool {
        let inList = filter.contains { f in part === f || part.isDescendant(of: f) }
        if filterType == 1 { return inList }
        return !inList
    }
}

public final class OverlapParamsV {
    public var filter: [Instance] = []
    public var filterType = 0
    public var maxParts = 0
    public var collisionGroup = "Default"
    public var respectCanCollide = false
    public init() {}
    func accepts(_ part: Instance) -> Bool {
        let inList = filter.contains { f in part === f || part.isDescendant(of: f) }
        return filterType == 1 ? inList : !inList
    }
}

public struct RaycastResultV {
    public var instance: Instance
    public var position: Vector3
    public var normal: Vector3
    public var distance: Float
    public var material: Int
    public init(instance: Instance, position: Vector3, normal: Vector3, distance: Float, material: Int) {
        self.instance = instance; self.position = position; self.normal = normal; self.distance = distance; self.material = material
    }
}

/// Handle to an AnimationTrack created by the Play session (port of engine/PlaySession.ScriptTrack).
public final class AnimTrackRef {
    public let owner: Instance
    public let animation: Instance
    public var isPlaying = false
    public var speed: Float = 1
    public var weight: Float = 1
    public var looped = false
    public var timePosition: Float = 0
    public var length: Float = 0
    public var priority = 2
    public var payload: AnyObject?
    public init(owner: Instance, animation: Instance) { self.owner = owner; self.animation = animation }
}

/// CollectionService tags, stored the way Roblox files store them ("Tags" BinaryString, NUL separated).
enum CollectionTags {
    static func tags(of i: Instance) -> [String] {
        switch i.get("Tags") {
        case .binaryString(let b)?: return String(decoding: b.bytes, as: UTF8.self).split(separator: "\0").map(String.init)
        case .string(let s)?: return s.split(separator: "\0").map(String.init)
        default: return []
        }
    }
    static func setTags(_ i: Instance, _ tags: [String]) {
        i.set("Tags", .binaryString(BinaryString(Data(tags.joined(separator: "\0").utf8))))
        i.propTypes["Tags"] = PropType.STRING
    }
    /// Stable owner object for CollectionService:GetInstanceAddedSignal(tag) etc.
    final class TagOwner { let tag: String; init(_ t: String) { tag = t } }
    private static var owners: [String: TagOwner] = [:]
    static func signalOwner(_ rt: ScriptRuntime, _ tag: String) -> TagOwner {
        if let o = owners[tag] { return o }
        let o = TagOwner(tag); owners[tag] = o; return o
    }
}
