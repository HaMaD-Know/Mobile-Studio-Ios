import Foundation
import StudioCore

/// Edit-mode animation & joint seating (port of engine/EditAnimation.kt):
/// - Registers temporary `KeyframeSequence` / `CurveAnimation` instances (`rbxtemp://` / `active://`)
///   for `KeyframeSequenceProvider` / `AnimationClipProvider`.
/// - Seats `Motor6D` joints and propagates transforms down their attached rig sub-assembly when
///   plugins or scripts assign `Motor6D.Transform`, `C0`, or `C1` in edit mode.
/// - Runs edit-mode `Animator:LoadAnimation` / `StepAnimations` tracks for animation editor plugins.
public final class EditAnimation {
    public static let shared = EditAnimation()

    private struct TempEntry {
        let inst: Instance
        var clip: AnimClip?
    }

    private final class EditTrack {
        let ref: AnimTrackRef
        var clip: AnimClip?
        var weight: Float = 0
        var targetWeight: Float = 1
        var fadeRate: Float = 10
        var stopping = false
        init(ref: AnimTrackRef, clip: AnimClip?) {
            self.ref = ref
            self.clip = clip
        }
    }

    private var seqCounter = 0
    private var registered: [String: TempEntry] = [:]
    private var dirtyMotors: [ObjectIdentifier: Instance] = [:]
    private var editTracks: [EditTrack] = []
    /// Optional asset loader for edit-mode `Animator:LoadAnimation` (set by the app).
    public var animLib = AnimLibrary()

    private init() {}

    // MARK: temp clip registration (KeyframeSequenceProvider / AnimationClipProvider)

    public func register(_ seq: Instance, active: Bool = false) -> String {
        seqCounter += 1
        let id = (active ? "active://" : "rbxtemp://") + String(seqCounter)
        let copy = seq.cloneTree()
        registered[id] = TempEntry(inst: copy, clip: AnimClip.fromInstance(copy))
        return id
    }

    public func clip(for id: String) -> AnimClip? {
        if let e = registered[id] {
            if let c = e.clip { return c }
            let built = AnimClip.fromInstance(e.inst)
            registered[id]?.clip = built
            return built
        }
        return animLib.clip(id)
    }

    public func instance(for id: String) -> Instance? {
        registered[id]?.inst.cloneTree()
    }

    public func clear() {
        registered.removeAll()
        dirtyMotors.removeAll()
        editTracks.removeAll()
    }

    // MARK: Motor6D seating in edit mode

    public func markDirty(_ motor: Instance) {
        guard motor.className == "Motor6D" || motor.className == "Motor" else { return }
        dirtyMotors[ObjectIdentifier(motor)] = motor
    }

    public func flush() {
        guard !dirtyMotors.isEmpty else { return }
        let motors = Array(dirtyMotors.values)
        dirtyMotors.removeAll()
        for m in motors where !m.destroyed {
            seat(m)
        }
    }

    /// Computes Part1's CFrame from `Part0.CFrame * C0 * Transform * C1^-1` and moves any unanchored
    /// assembly attached beyond Part1 by the same delta.
    public func seat(_ motor: Instance) {
        guard let p0 = motor.get("Part0")?.asInstance,
              let p1 = motor.get("Part1")?.asInstance,
              p0.isA("BasePart"), p1.isA("BasePart"), p0 !== p1 else { return }
        let c0 = motor.get("C0")?.asCFrame ?? .identity
        let c1 = motor.get("C1")?.asCFrame ?? .identity
        let tr = motor.get("Transform")?.asCFrame ?? .identity
        let old1 = PartData.cframe(p1)
        let new1 = PartData.cframe(p0) * c0 * tr * c1.inverse
        let delta = new1 * old1.inverse
        PartData.setCFrame(p1, new1)
        moveAssembly(beyond: p1, blocked: p0, by: delta)
    }

    private func moveAssembly(beyond start: Instance, blocked: Instance, by delta: CFrame) {
        let root = rigRoot(of: start)
        let joints = root.descendants().filter {
            ($0.isA("JointInstance") || $0.className == "WeldConstraint") && $0.get("Enabled")?.asBool != false
        }
        guard !joints.isEmpty else { return }
        var adj: [ObjectIdentifier: [Instance]] = [:]
        for j in joints {
            let a = j.get("Part0")?.asInstance ?? j.get("Part0Internal")?.asInstance
            let b = j.get("Part1")?.asInstance ?? j.get("Part1Internal")?.asInstance
            guard let a, let b, a.isA("BasePart"), b.isA("BasePart"), a !== b else { continue }
            adj[ObjectIdentifier(a), default: []].append(b)
            adj[ObjectIdentifier(b), default: []].append(a)
        }
        var visited: Set<ObjectIdentifier> = [ObjectIdentifier(blocked), ObjectIdentifier(start)]
        var queue: [Instance] = [start]
        var idx = 0
        while idx < queue.count {
            let cur = queue[idx]; idx += 1
            for next in adj[ObjectIdentifier(cur)] ?? [] {
                let k = ObjectIdentifier(next)
                guard !visited.contains(k) else { continue }
                visited.insert(k)
                if next.get("Anchored")?.asBool != true {
                    PartData.setCFrame(next, delta * PartData.cframe(next))
                    queue.append(next)
                }
            }
        }
    }

    private func rigRoot(of part: Instance) -> Instance {
        var cur = part
        while let p = cur.parent, p.isA("Model") || p.className == "Folder" || p.isA("Accoutrement") {
            cur = p
        }
        return cur
    }

    // MARK: edit-mode Animator tracks

    public func loadTrack(owner: Instance, animation: Instance) -> AnimTrackRef {
        let ref = AnimTrackRef(owner: owner, animation: animation)
        let id = animation.get("AnimationId")?.description ?? ""
        let c = clip(for: id)
        if let c {
            ref.length = c.length
            ref.looped = c.looped
            ref.priority = c.priority
        }
        editTracks.removeAll { !$0.ref.isPlaying && $0.ref.owner.parent == nil }
        editTracks.append(EditTrack(ref: ref, clip: c))
        return ref
    }

    public func playTrack(_ t: AnimTrackRef, fade: Float, weight: Float, speed: Float) {
        let tr = editTracks.first { $0.ref === t } ?? {
            let n = EditTrack(ref: t, clip: clip(for: t.animation.get("AnimationId")?.description ?? ""))
            editTracks.append(n)
            return n
        }()
        if tr.clip == nil { tr.clip = clip(for: t.animation.get("AnimationId")?.description ?? "") }
        if let c = tr.clip { t.length = c.length }
        t.isPlaying = true
        t.speed = speed
        t.weight = weight
        tr.stopping = false
        tr.targetWeight = weight
        tr.fadeRate = fade > 0 ? max(weight, 0.01) / fade : 1000
        if fade <= 0 { tr.weight = weight }
    }

    public func stopTrack(_ t: AnimTrackRef, fade: Float) {
        guard let tr = editTracks.first(where: { $0.ref === t }) else { t.isPlaying = false; return }
        t.isPlaying = false
        tr.stopping = true
        tr.targetWeight = 0
        tr.fadeRate = fade > 0 ? max(tr.weight, 0.01) / fade : 1000
        if fade <= 0 { tr.weight = 0 }
    }

    public func adjustTrack(_ t: AnimTrackRef, speed: Float?, weight: Float?, looped: Bool?, time: Float?) {
        let tr = editTracks.first { $0.ref === t }
        if let speed { t.speed = speed }
        if let weight { t.weight = weight; tr?.targetWeight = weight; tr?.fadeRate = 10 }
        if let looped { t.looped = looped }
        if let time { t.timePosition = time; if let tr { applyOwner(tr.ref.owner) } }
    }

    public func playingTracks(_ owner: Instance) -> [AnimTrackRef] {
        editTracks.filter { $0.ref.isPlaying && $0.ref.owner === owner }.map(\.ref)
    }

    public func stepAnimations(owner: Instance, dt: Float) {
        let list = editTracks.filter { $0.ref.owner === owner }
        guard !list.isEmpty else { return }
        advance(list, dt: dt)
        applyOwner(owner)
    }

    public func step(_ dt: Float) {
        guard !editTracks.isEmpty else { return }
        advance(editTracks, dt: dt)
        var owners: [ObjectIdentifier: Instance] = [:]
        for tr in editTracks where tr.weight > 0.001 || tr.ref.isPlaying {
            owners[ObjectIdentifier(tr.ref.owner)] = tr.ref.owner
        }
        for owner in owners.values { applyOwner(owner) }
        editTracks.removeAll { $0.stopping && $0.weight <= 0.001 }
    }

    private func advance(_ list: [EditTrack], dt: Float) {
        for tr in list {
            if tr.clip == nil {
                tr.clip = clip(for: tr.ref.animation.get("AnimationId")?.description ?? "")
                if let c = tr.clip { tr.ref.length = c.length }
            }
            if tr.ref.isPlaying, let c = tr.clip {
                tr.ref.timePosition += dt * tr.ref.speed
                if c.length > 0 && tr.ref.timePosition > c.length {
                    if tr.ref.looped {
                        tr.ref.timePosition = tr.ref.timePosition.truncatingRemainder(dividingBy: c.length)
                    } else {
                        tr.ref.timePosition = c.length
                        tr.ref.isPlaying = false
                        tr.stopping = true
                        tr.targetWeight = 0
                    }
                }
            }
            if tr.weight < tr.targetWeight { tr.weight = min(tr.targetWeight, tr.weight + tr.fadeRate * dt) }
            else if tr.weight > tr.targetWeight { tr.weight = max(tr.targetWeight, tr.weight - tr.fadeRate * dt) }
        }
    }

    private func applyOwner(_ owner: Instance) {
        let active = editTracks.filter { $0.ref.owner === owner && $0.weight > 0.001 && $0.clip != nil }
        guard !active.isEmpty else { return }
        let model = owner.parent ?? owner
        let motors = model.descendants().filter { $0.className == "Motor6D" }
        guard !motors.isEmpty else { return }
        // Seat top-down from root so child joints inherit updated parent frames.
        let ordered = orderMotors(motors, root: model.findFirstChild("HumanoidRootPart") ?? model.findFirstChild("Torso"))
        for m in ordered {
            guard let p1 = m.get("Part1")?.asInstance else { continue }
            let jointTracks = active.filter { $0.clip?.joints[p1.name] != nil }
            guard let topPrio = jointTracks.map({ $0.ref.priority }).max() else { continue }
            var blended: CFrame?
            var total: Float = 0
            for tr in jointTracks where tr.ref.priority == topPrio {
                guard let c = tr.clip, let cf = c.sample(p1.name, min(tr.ref.timePosition, c.length)) else { continue }
                total += tr.weight
                blended = blended.map { $0.lerp(cf, tr.weight / total) } ?? CFrame.identity.lerp(cf, min(1, tr.weight))
            }
            if let blended {
                m.set("Transform", .cframe(blended), notify: false)
                seat(m)
            }
        }
    }

    private func orderMotors(_ motors: [Instance], root: Instance?) -> [Instance] {
        guard let root else { return motors }
        var byP0: [ObjectIdentifier: [Instance]] = [:]
        for m in motors {
            if let p0 = m.get("Part0")?.asInstance { byP0[ObjectIdentifier(p0), default: []].append(m) }
        }
        var out: [Instance] = []
        var seen = Set<ObjectIdentifier>()
        var q: [Instance] = [root]
        var idx = 0
        while idx < q.count {
            let p = q[idx]; idx += 1
            for m in byP0[ObjectIdentifier(p)] ?? [] {
                if seen.insert(ObjectIdentifier(m)).inserted {
                    out.append(m)
                    if let p1 = m.get("Part1")?.asInstance { q.append(p1) }
                }
            }
        }
        for m in motors where seen.insert(ObjectIdentifier(m)).inserted { out.append(m) }
        return out
    }
}
