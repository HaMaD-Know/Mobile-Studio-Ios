import Foundation

/// Constructive Solid Geometry (port of engine/Csg.kt): BSP-tree boolean operations
/// (union, subtract, intersect) over primitive Roblox parts and nested unions.
public enum Csg {
    private static let eps: Float = 1e-4

    public struct Vertex: Hashable {
        public let pos: Vector3
        public let normal: Vector3

        public init(pos: Vector3, normal: Vector3) {
            self.pos = pos
            self.normal = normal
        }

        public func flipped() -> Vertex {
            Vertex(pos: pos, normal: -normal)
        }

        public func lerp(_ o: Vertex, _ t: Float) -> Vertex {
            Vertex(pos: pos.lerp(o.pos, t), normal: normal.lerp(o.normal, t))
        }
    }

    public struct Plane: Hashable {
        public let normal: Vector3
        public let w: Float

        public init(normal: Vector3, w: Float) {
            self.normal = normal
            self.w = w
        }

        public static func from(_ a: Vector3, _ b: Vector3, _ c: Vector3) -> Plane? {
            let n = (b - a).cross(c - a)
            guard n.magnitude >= 1e-9 else { return nil }
            let u = n.unit
            return Plane(normal: u, w: u.dot(a))
        }

        public func flipped() -> Plane {
            Plane(normal: -normal, w: -w)
        }

        public func split(_ p: Polygon,
                          coplanarFront: inout [Polygon],
                          coplanarBack: inout [Polygon],
                          front: inout [Polygon],
                          back: inout [Polygon]) {
            let verts = p.vertices
            var polyType = 0
            var types = [Int](repeating: 0, count: verts.count)
            for i in 0..<verts.count {
                let t = normal.dot(verts[i].pos) - w
                let type = t < -eps ? 2 : (t > eps ? 1 : 0)
                polyType |= type
                types[i] = type
            }
            switch polyType {
            case 0:
                if normal.dot(p.plane.normal) > 0 { coplanarFront.append(p) } else { coplanarBack.append(p) }
            case 1:
                front.append(p)
            case 2:
                back.append(p)
            default:
                var f: [Vertex] = []
                var b: [Vertex] = []
                let n = verts.count
                for i in 0..<n {
                    let j = (i + 1) % n
                    let ti = types[i], tj = types[j]
                    let vi = verts[i], vj = verts[j]
                    if ti != 2 { f.append(vi) }
                    if ti != 1 { b.append(vi) }
                    if (ti | tj) == 3 {
                        let denom = normal.dot(vj.pos - vi.pos)
                        let t = abs(denom) > 1e-9 ? (w - normal.dot(vi.pos)) / denom : 0.5
                        let v = vi.lerp(vj, t)
                        f.append(v)
                        b.append(v)
                    }
                }
                if f.count >= 3 { front.append(Polygon(vertices: f, shared: p.shared, plane: p.plane)) }
                if b.count >= 3 { back.append(Polygon(vertices: b, shared: p.shared, plane: p.plane)) }
            }
        }
    }

    public struct Polygon {
        public let vertices: [Vertex]
        public let shared: Int
        public let plane: Plane

        public init(vertices: [Vertex], shared: Int, plane: Plane) {
            self.vertices = vertices
            self.shared = shared
            self.plane = plane
        }

        public func flipped() -> Polygon {
            Polygon(vertices: vertices.reversed().map { $0.flipped() }, shared: shared, plane: plane.flipped())
        }
    }

    public final class Node {
        public var plane: Plane?
        public var front: Node?
        public var back: Node?
        public var polygons: [Polygon] = []

        public init(_ polys: [Polygon]? = nil) {
            if let polys { build(polys) }
        }

        public func clone() -> Node {
            let n = Node()
            n.plane = plane
            n.front = front?.clone()
            n.back = back?.clone()
            n.polygons = polygons
            return n
        }

        public func invert() {
            for i in 0..<polygons.count { polygons[i] = polygons[i].flipped() }
            plane = plane?.flipped()
            front?.invert()
            back?.invert()
            swap(&front, &back)
        }

        public func clipPolygons(_ polys: [Polygon]) -> [Polygon] {
            guard let plane else { return polys }
            var f: [Polygon] = []
            var b: [Polygon] = []
            for p in polys {
                plane.split(p, coplanarFront: &f, coplanarBack: &b, front: &f, back: &b)
            }
            var out = front?.clipPolygons(f) ?? f
            if let back {
                out.append(contentsOf: back.clipPolygons(b))
            }
            return out
        }

        public func clipTo(_ bsp: Node) {
            polygons = bsp.clipPolygons(polygons)
            front?.clipTo(bsp)
            back?.clipTo(bsp)
        }

        public func allPolygons() -> [Polygon] {
            var out = polygons
            if let front { out.append(contentsOf: front.allPolygons()) }
            if let back { out.append(contentsOf: back.allPolygons()) }
            return out
        }

        public func build(_ polys: [Polygon]) {
            guard !polys.isEmpty else { return }
            var node = self
            var list = polys
            while !list.isEmpty {
                if node.plane == nil { node.plane = list[0].plane }
                let pl = node.plane!
                var f: [Polygon] = []
                var b: [Polygon] = []
                for p in list {
                    pl.split(p, coplanarFront: &node.polygons, coplanarBack: &node.polygons, front: &f, back: &b)
                }
                if !b.isEmpty {
                    if node.back == nil { node.back = Node() }
                    node.back!.build(b)
                }
                if f.isEmpty { return }
                if node.front == nil { node.front = Node() }
                node = node.front!
                list = f
            }
        }
    }

    // MARK: Boolean operations

    public static func union(_ a: [Polygon], _ b: [Polygon]) -> [Polygon] {
        let na = Node(a), nb = Node(b)
        na.clipTo(nb)
        nb.clipTo(na)
        nb.invert()
        nb.clipTo(na)
        nb.invert()
        na.build(nb.allPolygons())
        return na.allPolygons()
    }

    public static func subtract(_ a: [Polygon], _ b: [Polygon]) -> [Polygon] {
        let na = Node(a), nb = Node(b)
        na.invert()
        na.clipTo(nb)
        nb.clipTo(na)
        nb.invert()
        nb.clipTo(na)
        nb.invert()
        na.build(nb.allPolygons())
        na.invert()
        return na.allPolygons()
    }

    public static func intersect(_ a: [Polygon], _ b: [Polygon]) -> [Polygon] {
        let na = Node(a), nb = Node(b)
        na.invert()
        nb.clipTo(na)
        nb.invert()
        na.clipTo(nb)
        nb.clipTo(na)
        na.build(nb.allPolygons())
        na.invert()
        return na.allPolygons()
    }

    // MARK: Part -> Polygons

    private static func poly(_ pts: [Vector3], shared: Int, smooth: [Vector3]? = nil) -> Polygon? {
        guard pts.count >= 3, let pl = Plane.from(pts[0], pts[1], pts[2]) else { return nil }
        let verts = pts.enumerated().map { i, pt in
            Vertex(pos: pt, normal: smooth?[i] ?? pl.normal)
        }
        return Polygon(vertices: verts, shared: shared, plane: pl)
    }

    private static func orient(_ p: Polygon, outward: Vector3) -> Polygon {
        p.plane.normal.dot(outward) < 0 ? p.flipped() : p
    }

    private static func addOriented(_ out: inout [Polygon], _ local: [Vector3], _ cf: CFrame, _ shared: Int, _ outwardLocal: Vector3) {
        let world = local.map { cf * $0 }
        guard let p = poly(world, shared: shared) else { return }
        let outward = cf.vectorToWorld(outwardLocal)
        out.append(p.plane.normal.dot(outward) < 0 ? p.flipped() : p)
    }

    private static func transform(_ p: Polygon, _ cf: CFrame, _ shared: Int) -> Polygon {
        let verts = p.vertices.map { Vertex(pos: cf * $0.pos, normal: cf.vectorToWorld($0.normal).unit) }
        let pl = Plane.from(verts[0].pos, verts[1].pos, verts[2].pos) ?? p.plane
        return Polygon(vertices: verts, shared: shared, plane: pl)
    }

    public static func partPolygons(_ p: Instance, shared: Int, toLocal: CFrame? = nil,
                                    cache: (Instance) -> [Polygon]? = { _ in nil }) -> [Polygon] {
        let partCF = PartData.cframe(p)
        let cf = toLocal.map { $0.inverse * partCF } ?? partCF

        if p.isA("PartOperation") && p.className != "NegateOperation" {
            guard let cached = cache(p) else { return [] }
            return cached.map { transform($0, cf, shared) }
        }

        let size = PartData.size(p)
        let h = size * 0.5
        var out: [Polygon] = []

        switch PartData.shape(p) {
        case .ball:
            let r = min(size.x, min(size.y, size.z)) * 0.5
            let stacks = 10, slices = 16
            func spherePt(_ i: Int, _ j: Int) -> Vector3 {
                let phi = Double(i) * .pi / Double(stacks)
                let theta = Double(j) * 2.0 * .pi / Double(slices)
                return Vector3(Float(sin(phi) * cos(theta)) * r,
                               Float(cos(phi)) * r,
                               Float(sin(phi) * sin(theta)) * r)
            }
            for i in 0..<stacks {
                for j in 0..<slices {
                    let p0 = spherePt(i, j), p1 = spherePt(i, j + 1)
                    let p2 = spherePt(i + 1, j + 1), p3 = spherePt(i + 1, j)
                    let local: [Vector3]
                    if i == 0 { local = [p0, p2, p3] }
                    else if i == stacks - 1 { local = [p0, p1, p2] }
                    else { local = [p0, p1, p2, p3] }
                    var world = local.map { cf * $0 }
                    var nrms = local.map { cf.vectorToWorld($0.unit) }
                    guard var pl = Plane.from(world[0], world[1], world[2]) else { continue }
                    if pl.normal.dot(nrms[0]) < 0 {
                        world.reverse()
                        nrms.reverse()
                        guard let flippedPl = Plane.from(world[0], world[1], world[2]) else { continue }
                        pl = flippedPl
                    }
                    let verts = zip(world, nrms).map { Vertex(pos: $0, normal: $1) }
                    out.append(Polygon(vertices: verts, shared: shared, plane: pl))
                }
            }

        case .cylinder:
            let r = min(size.y, size.z) * 0.5
            let segs = 20
            let ring = (0..<segs).map { i -> Vector3 in
                let a = Double(i) * 2.0 * .pi / Double(segs)
                return Vector3(0, Float(Double(r) * cos(a)), Float(Double(r) * sin(a)))
            }
            for i in 0..<segs {
                let a = ring[i], b = ring[(i + 1) % segs]
                let local = [
                    Vector3(-h.x, a.y, a.z), Vector3(h.x, a.y, a.z),
                    Vector3(h.x, b.y, b.z), Vector3(-h.x, b.y, b.z),
                ]
                let na = Vector3(0, a.y, a.z).unit, nb = Vector3(0, b.y, b.z).unit
                let localN = [na, na, nb, nb]
                var world = local.map { cf * $0 }
                var nrms = localN.map { cf.vectorToWorld($0) }
                guard var pl = Plane.from(world[0], world[1], world[2]) else { continue }
                if pl.normal.dot(nrms[0]) < 0 {
                    world.reverse()
                    nrms.reverse()
                    guard let flippedPl = Plane.from(world[0], world[1], world[2]) else { continue }
                    pl = flippedPl
                }
                out.append(Polygon(vertices: zip(world, nrms).map { Vertex(pos: $0, normal: $1) }, shared: shared, plane: pl))
            }
            let capPos = ring.map { cf * Vector3(h.x, $0.y, $0.z) }
            if let p = poly(capPos, shared: shared) { out.append(orient(p, outward: cf.vectorToWorld(Vector3(1, 0, 0)))) }
            let capNeg = ring.reversed().map { cf * Vector3(-h.x, $0.y, $0.z) }
            if let p = poly(capNeg, shared: shared) { out.append(orient(p, outward: cf.vectorToWorld(Vector3(-1, 0, 0)))) }

        case .wedge:
            let v0 = Vector3(-h.x, -h.y, -h.z), v1 = Vector3(h.x, -h.y, -h.z)
            let v2 = Vector3(-h.x, -h.y, h.z), v3 = Vector3(h.x, -h.y, h.z)
            let v4 = Vector3(-h.x, h.y, h.z), v5 = Vector3(h.x, h.y, h.z)
            addOriented(&out, [v0, v1, v3, v2], cf, shared, Vector3(0, -1, 0))
            addOriented(&out, [v2, v3, v5, v4], cf, shared, Vector3(0, 0, 1))
            addOriented(&out, [v0, v1, v5, v4], cf, shared, Vector3(0, size.z, -size.y).unit)
            addOriented(&out, [v0, v2, v4], cf, shared, Vector3(-1, 0, 0))
            addOriented(&out, [v1, v3, v5], cf, shared, Vector3(1, 0, 0))

        case .cornerWedge:
            let apex = Vector3(h.x, h.y, -h.z)
            let b0 = Vector3(-h.x, -h.y, -h.z), b1 = Vector3(h.x, -h.y, -h.z)
            let b2 = Vector3(h.x, -h.y, h.z), b3 = Vector3(-h.x, -h.y, h.z)
            let inside = Vector3(h.x * 0.4, -h.y * 0.5, -h.z * 0.4)
            let faces: [[Vector3]] = [
                [b0, b1, b2, b3], [b1, b2, apex], [b0, b1, apex], [b0, b3, apex], [b3, b2, apex],
            ]
            for f in faces {
                var sum = Vector3.zero
                for v in f { sum += v }
                let outward = (sum / Float(f.count) - inside).unit
                addOriented(&out, f, cf, shared, outward)
            }

        case .block:
            var c = [Vector3](repeating: .zero, count: 8)
            for i in 0..<8 {
                c[i] = Vector3(i & 1 != 0 ? h.x : -h.x, i & 2 != 0 ? h.y : -h.y, i & 4 != 0 ? h.z : -h.z)
            }
            addOriented(&out, [c[0], c[2], c[3], c[1]], cf, shared, Vector3(0, 0, -1))
            addOriented(&out, [c[4], c[5], c[7], c[6]], cf, shared, Vector3(0, 0, 1))
            addOriented(&out, [c[0], c[1], c[5], c[4]], cf, shared, Vector3(0, -1, 0))
            addOriented(&out, [c[2], c[6], c[7], c[3]], cf, shared, Vector3(0, 1, 0))
            addOriented(&out, [c[0], c[4], c[6], c[2]], cf, shared, Vector3(-1, 0, 0))
            addOriented(&out, [c[1], c[3], c[7], c[5]], cf, shared, Vector3(1, 0, 0))
        }
        return out
    }

    // MARK: Triangulation (8 floats/vertex: pos3 + normal3 + uv2)

    public static func toTriangles(_ polys: [Polygon]) -> [Int: [Float]] {
        var out: [Int: [Float]] = [:]
        for p in polys {
            let verts = p.vertices
            guard verts.count >= 3 else { continue }
            let n = p.plane.normal
            var dotSum: Double = 0
            for v in verts { dotSum += Double(v.normal.dot(n)) }
            let flat = abs(dotSum / Double(verts.count) - 1.0) < 0.001
            let an = n.abs
            var arr = out[p.shared] ?? []
            arr.reserveCapacity(arr.count + (verts.count - 2) * 24)
            for i in 1..<(verts.count - 1) {
                for v in [verts[0], verts[i], verts[i + 1]] {
                    let vn = flat ? n : v.normal
                    arr.append(v.pos.x); arr.append(v.pos.y); arr.append(v.pos.z)
                    arr.append(vn.x); arr.append(vn.y); arr.append(vn.z)
                    if an.y >= an.x && an.y >= an.z {
                        arr.append(v.pos.x); arr.append(v.pos.z)
                    } else if an.x >= an.z {
                        arr.append(v.pos.z); arr.append(v.pos.y)
                    } else {
                        arr.append(v.pos.x); arr.append(v.pos.y)
                    }
                }
            }
            out[p.shared] = arr
        }
        return out
    }
}
