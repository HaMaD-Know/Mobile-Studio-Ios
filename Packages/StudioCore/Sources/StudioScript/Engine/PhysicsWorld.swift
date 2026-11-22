import Foundation
import StudioCore

/// Simplified rigid-body world (stands in for the Android PlaySession's body/grid/collision code):
/// unanchored parts joined by welds/motors form assemblies that fall under gravity and collide
/// (translation only) with everything else; characters use a kinematic box mover.
final class PhysicsWorld {
    final class Body {
        let root: Instance
        var parts: [Instance]
        var velocity = Vector3.zero
        var mass: Float = 1
        var asleep = false
        var restTime: Float = 0
        init(root: Instance, parts: [Instance]) { self.root = root; self.parts = parts }
    }

    struct Joint {
        let inst: Instance
        let p0: Instance
        let p1: Instance
        /// Fixed offset p0 -> p1 for WeldConstraints (captured when the world is built).
        let rel: CFrame?
    }

    var dirty = true
    private(set) var bodies: [Body] = []
    private var bodyOf: [ObjectIdentifier: Body] = [:]
    private var joints: [Joint] = []
    /// Joints in root-outward order; `forward` = drive p1 from p0.
    private var solveOrder: [(Joint, Bool)] = []
    private var partsById: [ObjectIdentifier: Instance] = [:]
    private var grid: [Int64: [Instance]] = [:]
    private var gridOf: [ObjectIdentifier: [Int64]] = [:]
    private let cell: Float = 8
    private var characterParts = Set<ObjectIdentifier>()
    /// Workspace.Terrain and its voxels (collides with characters and raycasts).
    private(set) var terrain: Instance?
    private var terrainGrid: TerrainGrid?

    func part(_ id: ObjectIdentifier) -> Instance? { partsById[id] }
    func body(of p: Instance) -> Body? { bodyOf[ObjectIdentifier(p)] }

    // MARK: building

    func rebuild(_ ws: Instance, character: Instance?) {
        dirty = false
        bodies.removeAll(); bodyOf.removeAll(); joints.removeAll(); solveOrder.removeAll(); partsById.removeAll(); grid.removeAll(); gridOf.removeAll()
        characterParts = Set(character?.descendants().filter { $0.isA("BasePart") }.map(ObjectIdentifier.init) ?? [])
        let parts = ws.descendants().filter { $0.isA("BasePart") && $0.className != "Terrain" }
        terrain = ws.findFirstChildOfClass("Terrain")
        terrainGrid = terrain.flatMap { TerrainStore.hasVoxels($0) ? TerrainStore.of($0) : nil }
        for p in parts { partsById[ObjectIdentifier(p)] = p; insertGrid(p) }

        // Joints and union-find of connected parts.
        var parent: [ObjectIdentifier: ObjectIdentifier] = [:]
        func find(_ x: ObjectIdentifier) -> ObjectIdentifier {
            var r = x
            while let p = parent[r], p != r { r = p }
            return r
        }
        func union(_ a: ObjectIdentifier, _ b: ObjectIdentifier) { parent[find(a)] = find(b) }
        for p in parts { parent[ObjectIdentifier(p)] = ObjectIdentifier(p) }
        for j in ws.descendants() where (j.isA("JointInstance") || j.className == "WeldConstraint") && j.get("Enabled")?.asBool != false {
            let p0 = (j.get("Part0") ?? j.get("Part0Internal"))?.asInstance
            let p1 = (j.get("Part1") ?? j.get("Part1Internal"))?.asInstance
            guard let a = p0, let b = p1, partsById[ObjectIdentifier(a)] != nil, partsById[ObjectIdentifier(b)] != nil else { continue }
            let rel: CFrame? = j.className == "WeldConstraint" ? PartData.cframe(a).inverse * PartData.cframe(b) : nil
            joints.append(Joint(inst: j, p0: a, p1: b, rel: rel))
            union(ObjectIdentifier(a), ObjectIdentifier(b))
        }
        var groups: [ObjectIdentifier: [Instance]] = [:]
        for p in parts { groups[find(ObjectIdentifier(p)), default: []].append(p) }
        for (_, members) in groups {
            // Anchored anywhere = static assembly; character handled kinematically.
            if members.contains(where: { $0.get("Anchored")?.asBool == true }) { continue }
            if members.contains(where: { characterParts.contains(ObjectIdentifier($0)) }) { continue }
            let root = members.max { PartData.size($0).magnitude < PartData.size($1).magnitude }!
            let b = Body(root: root, parts: members)
            b.mass = max(0.01, members.reduce(0) { $0 + Physics.mass($1) })
            if let v = root.get("Velocity")?.asVector3 { b.velocity = v }
            bodies.append(b)
            for m in members { bodyOf[ObjectIdentifier(m)] = b }
        }
        // Order joints breadth-first from roots: anchored parts, body roots, the character root.
        var placed = Set<ObjectIdentifier>()
        var queue: [Instance] = parts.filter { $0.get("Anchored")?.asBool == true && !characterParts.contains(ObjectIdentifier($0)) }
        queue += bodies.map(\.root)
        if let ch = character, let r = ch.findFirstChild("HumanoidRootPart") ?? ch.findFirstChild("Torso") { queue.append(r) }
        for q in queue { placed.insert(ObjectIdentifier(q)) }
        var adj: [ObjectIdentifier: [Joint]] = [:]
        for j in joints { adj[ObjectIdentifier(j.p0), default: []].append(j); adj[ObjectIdentifier(j.p1), default: []].append(j) }
        var head = 0
        while head < queue.count {
            let cur = queue[head]; head += 1
            for j in adj[ObjectIdentifier(cur)] ?? [] {
                let fwd = j.p0 === cur
                let other = fwd ? j.p1 : j.p0
                if placed.insert(ObjectIdentifier(other)).inserted {
                    solveOrder.append((j, fwd))
                    queue.append(other)
                }
            }
        }
    }

    private func key(_ x: Int, _ y: Int, _ z: Int) -> Int64 {
        (Int64(x & 0x1FFFFF) << 42) | (Int64(y & 0x1FFFFF) << 21) | Int64(z & 0x1FFFFF)
    }
    private func cells(_ lo: Vector3, _ hi: Vector3) -> [Int64] {
        let x0 = Int(floor(lo.x / cell)), x1 = Int(floor(hi.x / cell))
        let y0 = Int(floor(lo.y / cell)), y1 = Int(floor(hi.y / cell))
        let z0 = Int(floor(lo.z / cell)), z1 = Int(floor(hi.z / cell))
        // Huge parts (baseplates) would fill thousands of cells: cap the span and keep them in a shared list.
        if (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) > 512 { return [Int64.min] }
        var out: [Int64] = []
        for x in x0...x1 { for y in y0...y1 { for z in z0...z1 { out.append(key(x, y, z)) } } }
        return out
    }
    private func insertGrid(_ p: Instance) {
        let (lo, hi) = Geometry.aabb(p)
        let ks = cells(lo, hi)
        gridOf[ObjectIdentifier(p)] = ks
        for k in ks { grid[k, default: []].append(p) }
    }
    private func removeGrid(_ p: Instance) {
        guard let ks = gridOf.removeValue(forKey: ObjectIdentifier(p)) else { return }
        for k in ks { grid[k]?.removeAll { $0 === p } }
    }
    func moved(_ p: Instance) {
        guard partsById[ObjectIdentifier(p)] != nil else { return }
        removeGrid(p); insertGrid(p)
    }

    /// Parts whose cells overlap an AABB.
    func query(_ box: (Vector3, Vector3), expand: Float = 0) -> [Instance] {
        let lo = box.0 - Vector3(expand, expand, expand), hi = box.1 + Vector3(expand, expand, expand)
        var seen = Set<ObjectIdentifier>()
        var out: [Instance] = []
        let ks = cells(lo, hi)
        for k in (ks == [Int64.min] ? Array(grid.keys) : ks + [Int64.min]) {
            for p in grid[k] ?? [] where seen.insert(ObjectIdentifier(p)).inserted {
                let (a, b) = Geometry.aabb(p)
                if a.x <= hi.x && b.x >= lo.x && a.y <= hi.y && b.y >= lo.y && a.z <= hi.z && b.z >= lo.z { out.append(p) }
            }
        }
        return out
    }

    // MARK: joints

    /// Place jointed parts from their assembly root outward (Motor6D uses C0 * Transform * C1^-1).
    func solveJoints(only: Instance? = nil) {
        for (j, fwd) in solveOrder {
            if let only, !(j.p0.isDescendant(of: only) && j.p1.isDescendant(of: only)) { continue }
            if fwd {
                if j.p1.get("Anchored")?.asBool == true && !characterParts.contains(ObjectIdentifier(j.p1)) { continue }
                PartData.setCFrame(j.p1, PartData.cframe(j.p0) * offset(j))
            } else {
                if j.p0.get("Anchored")?.asBool == true && !characterParts.contains(ObjectIdentifier(j.p0)) { continue }
                PartData.setCFrame(j.p0, PartData.cframe(j.p1) * offset(j).inverse)
            }
        }
    }

    private func offset(_ j: Joint) -> CFrame {
        if let rel = j.rel { return rel }
        let c0 = j.inst.get("C0")?.asCFrame ?? .identity, c1 = j.inst.get("C1")?.asCFrame ?? .identity
        let t = j.inst.get("Transform")?.asCFrame ?? .identity
        return c0 * t * c1.inverse
    }

    // MARK: simulation

    func step(_ dt: Float, gravity: Float, exclude: Instance?) {
        for b in bodies where !b.asleep {
            guard b.root.parent != nil else { continue }
            b.velocity.y -= gravity * dt
            let move = b.velocity * dt
            for p in b.parts { PartData.setCFrame(p, PartData.cframe(p) + move) }
            var onGround = false
            // Resolve penetrations against everything that isn't this body.
            for _ in 0..<3 {
                var pushed = false
                for p in b.parts where p.get("CanCollide")?.asBool != false {
                    for o in query(Geometry.aabb(p)) where bodyOf[ObjectIdentifier(o)] !== b && o.get("CanCollide")?.asBool != false {
                        if characterParts.contains(ObjectIdentifier(o)) { continue }
                        guard Physics.collidable(p.get("CollisionGroup")?.asString ?? "Default", o.get("CollisionGroup")?.asString ?? "Default") else { continue }
                        guard let (n, depth) = penetration(p, o) else { continue }
                        let fix = n * depth
                        for q in b.parts { PartData.setCFrame(q, PartData.cframe(q) + fix) }
                        let vn = b.velocity.dot(n)
                        if vn < 0 {
                            let e = PhysicsMaterials.props(PartData.material(p)).2
                            b.velocity -= n * (vn * (1 + (abs(vn) > 8 ? e : 0)))
                            // Friction on the tangent.
                            let f = PhysicsMaterials.props(PartData.material(p)).1
                            let tangent = b.velocity - n * b.velocity.dot(n)
                            b.velocity -= tangent * min(1, f * 4 * dt * 10)
                        }
                        if n.y > 0.6 { onGround = true }
                        pushed = true
                    }
                }
                if !pushed { break }
            }
            for p in b.parts { moved(p) }
            if onGround && b.velocity.magnitude < 0.3 {
                b.restTime += dt
                if b.restTime > 1 { b.asleep = true; b.velocity = .zero }
            } else { b.restTime = 0 }
        }
    }

    /// Minimum translation (normal pointing out of `b` into `a`) separating two parts' boxes.
    func penetration(_ a: Instance, _ b: Instance) -> (Vector3, Float)? {
        let ca = PartData.cframe(a), cb = PartData.cframe(b)
        let ha = PartData.size(a) * 0.5, hb = PartData.size(b) * 0.5
        let axesA = [ca.rightVector, ca.upVector, ca.backVector], axesB = [cb.rightVector, cb.upVector, cb.backVector]
        var axes = axesA + axesB
        for x in axesA { for y in axesB { let c = x.cross(y); if c.magnitude > 1e-4 { axes.append(c.unit) } } }
        let t = ca.position - cb.position
        var best: (Vector3, Float)?
        for ax in axes {
            let ra = abs(axesA[0].dot(ax)) * ha.x + abs(axesA[1].dot(ax)) * ha.y + abs(axesA[2].dot(ax)) * ha.z
            let rb = abs(axesB[0].dot(ax)) * hb.x + abs(axesB[1].dot(ax)) * hb.y + abs(axesB[2].dot(ax)) * hb.z
            let d = t.dot(ax)
            let overlap = ra + rb - abs(d)
            if overlap <= 0 { return nil }
            if overlap < (best?.1 ?? .greatestFiniteMagnitude) { best = (d < 0 ? -ax : ax, overlap) }
        }
        return best
    }

    // MARK: character mover

    /// Move a character box (2 x 5 x 2 around the root, feet 3 studs below it) with step-up.
    func moveCharacter(from pos: Vector3, velocity: Vector3, dt: Float, ignore: Instance) -> (Vector3, Bool, Instance?) {
        let half = Vector3(0.9, 2.4, 0.9)
        let centerOffset = Vector3(0, -0.5, 0)
        func blockers(_ p: Vector3) -> [Instance] {
            query((p + centerOffset - half, p + centerOffset + half)).filter {
                $0.get("CanCollide")?.asBool != false && !$0.isDescendant(of: ignore) &&
                    Geometry.obbOverlap(.at(p + centerOffset), half, PartData.cframe($0), PartData.size($0) * 0.5)
            }
        }
        let grid = terrainGrid
        func terrainBlocked(_ p: Vector3) -> Bool {
            guard let grid else { return false }
            let c = p + centerOffset
            for dy: Float in [-1.6, 0, 1.6] where TerrainMesher.density(grid, c + Vector3(0, dy, 0)) >= 0.5 { return true }
            return false
        }
        func blocked(_ p: Vector3) -> Bool { terrainBlocked(p) || !blockers(p).isEmpty }
        var p = pos
        // Horizontal, with up to 2 studs of step-up.
        let horiz = Vector3(velocity.x, 0, velocity.z) * dt
        if horiz.magnitude > 0 {
            let steps = max(1, Int(ceil(horiz.magnitude / 0.5)))
            let inc = horiz / Float(steps)
            for _ in 0..<steps {
                var cand = p + inc
                if blocked(cand) {
                    var stepped = false
                    for up in stride(from: Float(0.5), through: 2.1, by: 0.5) where !blocked(cand + Vector3(0, up, 0)) {
                        cand += Vector3(0, up, 0); stepped = true; break
                    }
                    if !stepped {
                        // Slide along the axis that isn't blocked.
                        let cx = p + Vector3(inc.x, 0, 0), cz = p + Vector3(0, 0, inc.z)
                        if !blocked(cx) { cand = cx } else if !blocked(cz) { cand = cz } else { break }
                    }
                }
                p = cand
            }
        }
        // Vertical.
        var grounded = false
        var groundPart: Instance?
        let dy = velocity.y * dt
        if dy > 0 {
            let cand = p + Vector3(0, dy, 0)
            if !blocked(cand) { p = cand }
        }
        // Ground probe: rays down from the root's footprint.
        let probe: Float = 3.05 + max(0, -dy)
        var best: (Float, Instance)?
        for o in [Vector3(0, 0, 0), Vector3(0.8, 0, 0.8), Vector3(-0.8, 0, 0.8), Vector3(0.8, 0, -0.8), Vector3(-0.8, 0, -0.8)] {
            if let h = raycastAll(origin: p + o, direction: Vector3(0, -probe, 0), ignore: ignore, accept: { $0.get("CanCollide")?.asBool != false }) {
                let d = h.t * probe
                if d < (best?.0 ?? .greatestFiniteMagnitude) { best = (d, h.part) }
            }
        }
        if let grid, let terrain, let h = TerrainMesher.raycast(grid, origin: p + Vector3(0, 1, 0), dir: Vector3(0, -1, 0), maxDist: probe + 1),
           h.t - 1 < (best?.0 ?? .greatestFiniteMagnitude) {
            best = (max(0, h.t - 1), terrain)
        }
        if let (d, part) = best, velocity.y <= 0 {
            p.y = p.y - d + 3
            grounded = true
            groundPart = part
        } else if dy < 0 {
            let cand = p + Vector3(0, dy, 0)
            if !blocked(cand) { p = cand } else { grounded = true }
        }
        return (p, grounded, groundPart)
    }

    // MARK: queries

    func raycastAll(origin: Vector3, direction: Vector3, ignore: Instance?, accept: (Instance) -> Bool = { _ in true }) -> Geometry.Hit? {
        let end = origin + direction
        let candidates = query((origin.min(end), origin.max(end)))
        let hit = Geometry.raycast(candidates, origin: origin, direction: direction) { p in
            (ignore == nil || !p.isDescendant(of: ignore!)) && PartData.transparency(p) < 1.0001 && accept(p)
        }
        let len = direction.magnitude
        if let grid = terrainGrid, let terrain, len > 0, accept(terrain),
           let th = TerrainMesher.raycast(grid, origin: origin, dir: direction / len, maxDist: len),
           th.t / len < (hit?.t ?? .greatestFiniteMagnitude) {
            return Geometry.Hit(part: terrain, t: th.t / len, point: th.point, normal: th.normal)
        }
        return hit
    }

    func raycastStatic(origin: Vector3, direction: Vector3) -> Geometry.Hit? {
        raycastAll(origin: origin, direction: direction, ignore: nil) { p in
            p.get("CanCollide")?.asBool != false && !self.characterParts.contains(ObjectIdentifier(p)) && PartData.transparency(p) < 0.95
        }
    }
}
