import Foundation

/// Solid Modeling (port of core/SolidModeling.kt): Union, Intersect, Negate and Separate,
/// with cached BSP meshes for PartOperations whose source parts are stored as children.
public enum SolidModeling {
    public struct Style {
        public let color: Color3
        public let transparency: Float
        public init(color: Color3, transparency: Float) {
            self.color = color
            self.transparency = transparency
        }
    }

    public final class Result {
        public let polys: [Csg.Polygon]
        public let tris: [Int: [Float]]
        public let styles: [Style]
        public let sig: Int64
        public let initialSize: Vector3
        public let offset: Vector3

        public init(polys: [Csg.Polygon], tris: [Int: [Float]], styles: [Style], sig: Int64, initialSize: Vector3, offset: Vector3) {
            self.polys = polys; self.tris = tris; self.styles = styles
            self.sig = sig; self.initialSize = initialSize; self.offset = offset
        }
    }

    private final class CacheEntry {
        weak var op: Instance?
        let result: Result
        init(_ op: Instance, _ result: Result) { self.op = op; self.result = result }
    }

    private static var cache: [ObjectIdentifier: CacheEntry] = [:]
    private static var failed: [ObjectIdentifier: Int64] = [:]
    private static let lock = NSLock()

    public static func isOperation(_ i: Instance) -> Bool {
        i.isA("PartOperation") && i.className != "NegateOperation"
    }

    /// True if `i` is a hidden source part inside a UnionOperation or IntersectOperation.
    public static func isHiddenSource(_ i: Instance) -> Bool {
        var cur = i.parent
        while let p = cur {
            if isOperation(p) { return true }
            cur = p.parent
        }
        return false
    }

    public static func sources(_ op: Instance) -> [Instance] {
        op.children.filter { $0.isA("BasePart") }
    }

    public static func canSeparate(_ op: Instance) -> Bool {
        isOperation(op) && !sources(op).isEmpty
    }

    public static func scaleOf(_ op: Instance, _ r: Result) -> Vector3 {
        let s = PartData.size(op)
        func k(_ a: Float, _ b: Float) -> Float { b > 1e-5 ? a / b : 1 }
        return Vector3(k(s.x, r.initialSize.x), k(s.y, r.initialSize.y), k(s.z, r.initialSize.z))
    }

    private static func boundsOf(_ parts: [Instance]) -> (min: Vector3, max: Vector3)? {
        guard !parts.isEmpty else { return nil }
        var lo = Vector3(.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = -lo
        for p in parts {
            let cf = PartData.cframe(p), h = PartData.size(p) * 0.5
            for sx: Float in [-1, 1] { for sy: Float in [-1, 1] { for sz: Float in [-1, 1] {
                let pt = cf * Vector3(h.x * sx, h.y * sy, h.z * sz)
                lo = lo.min(pt); hi = hi.max(pt)
            } } }
        }
        return (lo, hi)
    }

    private static func reference(_ srcs: [Instance]) -> (CFrame, Vector3)? {
        guard let (lo, hi) = boundsOf(srcs) else { return nil }
        return (.at((lo + hi) * 0.5), hi - lo)
    }

    private static func signature(_ op: Instance, _ srcs: [Instance]) -> Int64 {
        let usePartColor = op.get("UsePartColor")?.asBool == true
        var h = Int64(op.className.hashValue) &* 31 &+ (usePartColor ? 1 : 0)
        for s in srcs {
            h = h &* 31 &+ Int64(s.className.hashValue)
            h = h &* 31 &+ Int64(PartData.cframe(s).hashValue)
            h = h &* 31 &+ Int64(PartData.size(s).hashValue)
            h = h &* 31 &+ Int64(PartData.shape(s).rawValue)
            h = h &* 31 &+ Int64(PartData.color(s).hashValue)
            if isOperation(s) {
                let r = result(s)
                h = h &* 31 &+ (r?.sig ?? 0)
            }
        }
        if usePartColor { h = h &* 31 &+ Int64(PartData.color(op).hashValue) }
        return h
    }

    /// Cached CSG result for an operation whose source parts are stored as children.
    public static func result(_ op: Instance) -> Result? {
        guard isOperation(op) else { return nil }
        let srcs = sources(op)
        guard !srcs.isEmpty else { return nil }
        let sig = signature(op, srcs)
        let id = ObjectIdentifier(op)
        lock.lock()
        if let e = cache[id], e.op === op, e.result.sig == sig {
            lock.unlock()
            return e.result
        }
        if failed[id] == sig {
            lock.unlock()
            return nil
        }
        lock.unlock()

        guard let computed = compute(op, srcs, sig) else {
            lock.lock(); failed[id] = sig; lock.unlock()
            return nil
        }
        lock.lock()
        cache[id] = CacheEntry(op, computed)
        if cache.count > 128 { cache = cache.filter { $0.value.op != nil } }
        lock.unlock()
        return computed
    }

    private static func compute(_ op: Instance, _ srcs: [Instance], _ sig: Int64) -> Result? {
        guard let (refCF, refSize) = reference(srcs) else { return nil }
        var styles: [Style] = []
        let usePartColor = op.get("UsePartColor")?.asBool == true
        let solids = srcs.filter { $0.className != "NegateOperation" }
        let negates = srcs.filter { $0.className == "NegateOperation" }

        func polysOf(_ part: Instance) -> [Csg.Polygon] {
            let idx = styles.count
            styles.append(Style(color: usePartColor ? PartData.color(op) : PartData.color(part),
                                transparency: PartData.transparency(part)))
            return Csg.partPolygons(part, shared: idx, toLocal: refCF) { inner in
                scaledPolys(inner)
            }
        }

        var polys: [Csg.Polygon] = solids.isEmpty ? [] : polysOf(solids[0])
        for s in solids.dropFirst() {
            let b = polysOf(s)
            polys = op.className == "IntersectOperation" ? Csg.intersect(polys, b) : Csg.union(polys, b)
        }
        for n in negates {
            polys = Csg.subtract(polys, polysOf(n))
        }

        var lo = Vector3(.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = -lo
        for p in polys {
            for v in p.vertices { lo = lo.min(v.pos); hi = hi.max(v.pos) }
        }
        if polys.isEmpty {
            lo = -(refSize * 0.5)
            hi = refSize * 0.5
        }
        let offset = (lo + hi) * 0.5
        let centered: [Csg.Polygon]
        if offset.magnitude < 1e-5 {
            centered = polys
        } else {
            centered = polys.map { p in
                let verts = p.vertices.map { Csg.Vertex(pos: $0.pos - offset, normal: $0.normal) }
                let pl = Csg.Plane(normal: p.plane.normal, w: p.plane.w - p.plane.normal.dot(offset))
                return Csg.Polygon(vertices: verts, shared: p.shared, plane: pl)
            }
        }
        let initialSize = (hi - lo).max(Vector3(0.01, 0.01, 0.01))
        return Result(polys: centered, tris: Csg.toTriangles(centered), styles: styles, sig: sig,
                      initialSize: initialSize, offset: offset)
    }

    private static func scaledPolys(_ op: Instance) -> [Csg.Polygon]? {
        guard let r = result(op) else { return storedPolys(op) }
        let sc = scaleOf(op, r)
        if abs(sc.x - 1) < 1e-4 && abs(sc.y - 1) < 1e-4 && abs(sc.z - 1) < 1e-4 { return r.polys }
        return r.polys.compactMap { p in
            let verts = p.vertices.map { v in
                Csg.Vertex(pos: v.pos * sc, normal: (v.normal / sc).unit)
            }
            guard verts.count >= 3, let pl = Csg.Plane.from(verts[0].pos, verts[1].pos, verts[2].pos) else { return nil }
            return Csg.Polygon(vertices: verts, shared: p.shared, plane: pl)
        }
    }

    /// Fallback for unions created in Roblox Studio with inline CSGMDL bytes (no child parts).
    private static func storedPolys(_ op: Instance) -> [Csg.Polygon]? {
        guard let data = CsgMesh.inlineData(op), let mesh = try? CsgMesh.decode(data) else { return nil }
        let mn = Vector3(mesh.min[0], mesh.min[1], mesh.min[2])
        let mx = Vector3(mesh.max[0], mesh.max[1], mesh.max[2])
        let center = (mn + mx) * 0.5
        let rawSize = mx - mn
        let target = PartData.size(op)
        func k(_ a: Float, _ b: Float) -> Float { b > 1e-4 ? a / b : 1 }
        let sc = Vector3(k(target.x, rawSize.x), k(target.y, rawSize.y), k(target.z, rawSize.z))
        let v = mesh.vertices
        let triCount = v.count / 24
        var out: [Csg.Polygon] = []
        out.reserveCapacity(triCount)
        for t in 0..<triCount {
            let b = t * 24
            let p0 = (Vector3(v[b], v[b + 1], v[b + 2]) - center) * sc
            let p1 = (Vector3(v[b + 8], v[b + 9], v[b + 10]) - center) * sc
            let p2 = (Vector3(v[b + 16], v[b + 17], v[b + 18]) - center) * sc
            guard let pl = Csg.Plane.from(p0, p1, p2) else { continue }
            out.append(Csg.Polygon(vertices: [Csg.Vertex(pos: p0, normal: pl.normal),
                                              Csg.Vertex(pos: p1, normal: pl.normal),
                                              Csg.Vertex(pos: p2, normal: pl.normal)],
                                   shared: 0, plane: pl))
        }
        return out
    }

    // MARK: Editor operations

    private static func copyPartProps(from: Instance, to: Instance) {
        for (k, v) in from.props where k != "Name" {
            to.props[k] = v
            if let t = from.propTypes[k] { to.propTypes[k] = t }
        }
        to.props["Name"] = .string(from.name)
    }

    /// Toggles selected parts between solid parts and NegateOperation. Returns count changed.
    @discardableResult
    public static func negate(_ session: EditSession) -> Int {
        let targets = session.selection.filter { $0.isA("BasePart") && !isOperation($0) && $0.parent != nil }
        guard !targets.isEmpty else { return 0 }
        var replaced: [Instance] = []
        session.undo.begin("Negate")
        for inst in targets {
            guard let parent = inst.parent else { continue }
            let idx = inst.index(in: parent)
            let next: Instance
            if inst.className == "NegateOperation" {
                let cls: String
                if case .string(let saved)? = inst.attributes["__cls"] {
                    cls = saved
                } else {
                    switch PartData.shape(inst) {
                    case .wedge: cls = "WedgePart"
                    case .cornerWedge: cls = "CornerWedgePart"
                    default: cls = "Part"
                    }
                }
                next = InstanceFactory.create(cls)
                copyPartProps(from: inst, to: next)
                if cls != "Part" { next.props["shape"] = nil }
            } else {
                next = InstanceFactory.create("NegateOperation")
                copyPartProps(from: inst, to: next)
                next.attributes["__cls"] = .string(inst.className)
                next.props["shape"] = .enumValue(EnumValue(UInt32(PartData.shape(inst).rawValue)))
                next.propTypes["shape"] = 18
            }
            for ch in Array(inst.children) { try? session.reparent(ch, next) }
            try? session.reparent(inst, nil)
            try? session.reparent(next, parent)
            // Restore original sibling order when possible.
            if idx >= 0 && idx < parent.children.count, let curIdx = parent.children.firstIndex(where: { $0 === next }) {
                parent.children.remove(at: curIdx)
                parent.children.insert(next, at: min(idx, parent.children.count))
            }
            replaced.append(next)
        }
        session.undo.commit()
        session.select(replaced)
        return replaced.count
    }

    /// Combines selected parts into a UnionOperation or IntersectOperation. Returns error message on failure, nil on success.
    @discardableResult
    public static func combine(_ session: EditSession, intersect: Bool) -> String? {
        var parts: [Instance] = []
        var seen = Set<ObjectIdentifier>()
        func add(_ i: Instance) {
            if seen.insert(ObjectIdentifier(i)).inserted { parts.append(i) }
        }
        for sel in session.selection {
            if sel.isA("BasePart") {
                add(sel)
            } else if !sel.isService && (sel.isA("Model") || sel.className == "Folder") {
                for d in sel.descendants() where d.isA("BasePart") && !(d.parent?.isA("PartOperation") ?? false) {
                    add(d)
                }
            }
        }
        if parts.count < 2 && !parts.contains(where: { $0.className == "NegateOperation" }) {
            return "Select at least two parts to \(intersect ? "intersect" : "union")."
        }
        guard let firstSolid = parts.first(where: { $0.className != "NegateOperation" }) else {
            return "Select at least one part that isn't negated."
        }
        guard let (refCF, refSize) = reference(parts) else { return "Nothing to combine." }
        let parent = firstSolid.parent ?? session.model.workspace

        let op = InstanceFactory.create(intersect ? "IntersectOperation" : "UnionOperation")
        op.name = intersect ? "Intersection" : "Union"
        op.set("CFrame", .cframe(refCF), notify: false)
        op.set("size", .vector3(refSize), notify: false)
        op.set("Color3uint8", .color3(PartData.color(firstSolid)), notify: false)
        op.set("Material", .enumValue(EnumValue(UInt32(PartData.material(firstSolid)))), notify: false)
        op.set("Anchored", .bool(parts.contains { $0.get("Anchored")?.asBool == true }), notify: false)
        op.set("CanCollide", .bool(firstSolid.get("CanCollide")?.asBool != false), notify: false)
        op.set("Transparency", .float(PartData.transparency(firstSolid)), notify: false)
        op.set("UsePartColor", .bool(false), notify: false)
        op.set("SmoothingAngle", .float(0), notify: false)
        op.set("RenderFidelity", .enumValue(EnumValue(1)), notify: false)
        op.set("CollisionFidelity", .enumValue(EnumValue(0)), notify: false)
        for face in ["TopSurface", "BottomSurface", "FrontSurface", "BackSurface", "LeftSurface", "RightSurface"] {
            op.props[face] = nil
        }

        session.undo.begin(intersect ? "Intersect" : "Union")
        try? session.reparent(op, parent)
        for p in parts { try? session.reparent(p, op) }
        if let r = result(op) {
            op.set("CFrame", .cframe(refCF + r.offset), notify: false)
            op.set("size", .vector3(r.initialSize), notify: false)
        }
        session.undo.commit()
        session.select([op])
        return nil
    }

    /// Separates selected unions/intersections back into their source parts, and un-negates selected NegateOperations.
    @discardableResult
    public static func separate(_ session: EditSession) -> String? {
        let targets = session.selection.filter { (isOperation($0) || $0.className == "NegateOperation") && $0.parent != nil }
        guard !targets.isEmpty else {
            return "Select a union, intersection or negated part to separate."
        }
        var restored: [Instance] = []
        var sawExternal = false
        let negates = targets.filter { $0.className == "NegateOperation" }
        let ops = targets.filter { isOperation($0) }

        if !ops.isEmpty {
            session.undo.begin("Separate")
            for op in ops {
                let srcs = sources(op)
                if srcs.isEmpty { sawExternal = true; continue }
                guard let (refCF, _) = reference(srcs), let parent = op.parent else { continue }
                let r = result(op)
                let sc = r.map { scaleOf(op, $0) } ?? .one
                let opCF = PartData.cframe(op)
                let off = r?.offset ?? .zero
                for s in srcs {
                    let localCF = refCF.inverse * PartData.cframe(s)
                    let newPos = opCF * ((localCF.position - off) * sc)
                    let newRot = opCF.rotationOnly * localCF.rotationOnly
                    let sx = (localCF.rightVector * sc).magnitude
                    let sy = (localCF.upVector * sc).magnitude
                    let sz = (localCF.backVector * sc).magnitude
                    let oldSize = PartData.size(s)
                    try? session.reparent(s, parent)
                    session.setProp(s, "CFrame", .cframe(newRot.withPosition(newPos)))
                    let sizeKey = s.props.contains("size") ? "size" : "Size"
                    session.setProp(s, sizeKey, .vector3(Vector3(oldSize.x * sx, oldSize.y * sy, oldSize.z * sz)))
                    restored.append(s)
                }
                try? session.reparent(op, nil)
            }
            session.undo.commit()
        }

        if !negates.isEmpty {
            session.select(negates)
            _ = negate(session)
            if !restored.isEmpty {
                session.select(restored + session.selection)
            }
        } else if !restored.isEmpty {
            session.select(restored)
        }

        if sawExternal && restored.isEmpty && negates.isEmpty {
            return "That union was made in Roblox Studio; the parts it was made from aren't stored in the file, so it can't be separated here."
        }
        return nil
    }
}
