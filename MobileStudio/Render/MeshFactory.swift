import Metal
import simd

/// GPU mesh: interleaved float3 position + float3 normal, drawn as a triangle list.
struct GPUMesh {
    let buffer: MTLBuffer
    let vertexCount: Int
    let primitive: MTLPrimitiveType
}

/// Unit-sized meshes for the part shapes (port of render/Meshes.kt) plus overlay shapes.
enum MeshFactory {
    struct Builder {
        var data: [Float] = []
        /// A point inside the solid; flat triangles are oriented to face away from it.
        var inside = SIMD3<Float>(0, 0, 0)

        mutating func vert(_ p: SIMD3<Float>, _ n: SIMD3<Float>) { data += [p.x, p.y, p.z, n.x, n.y, n.z] }

        mutating func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            var n = simd_normalize(simd_cross(b - a, c - a))
            let center = (a + b + c) / 3
            if simd_dot(n, center - inside) < 0 { n = -n; vert(a, n); vert(c, n); vert(b, n) } else { vert(a, n); vert(b, n); vert(c, n) }
        }
        mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            tri(a, b, c); tri(a, c, d)
        }
        mutating func smoothTri(_ a: SIMD3<Float>, _ na: SIMD3<Float>, _ b: SIMD3<Float>, _ nb: SIMD3<Float>, _ c: SIMD3<Float>, _ nc: SIMD3<Float>) {
            vert(a, na); vert(b, nb); vert(c, nc)
        }
        func upload(_ device: MTLDevice, _ prim: MTLPrimitiveType = .triangle) -> GPUMesh {
            let buf = device.makeBuffer(bytes: data, length: max(4, data.count * 4), options: .storageModeShared)!
            return GPUMesh(buffer: buf, vertexCount: data.count / 6, primitive: prim)
        }
    }

    static func v(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { SIMD3(x, y, z) }

    static func cube(_ d: MTLDevice) -> GPUMesh {
        var b = Builder()
        var c = [SIMD3<Float>](repeating: .zero, count: 8)
        for i in 0..<8 { c[i] = v(i & 1 != 0 ? 0.5 : -0.5, i & 2 != 0 ? 0.5 : -0.5, i & 4 != 0 ? 0.5 : -0.5) }
        b.quad(c[0], c[1], c[3], c[2]); b.quad(c[4], c[5], c[7], c[6])
        b.quad(c[0], c[1], c[5], c[4]); b.quad(c[2], c[3], c[7], c[6])
        b.quad(c[0], c[2], c[6], c[4]); b.quad(c[1], c[3], c[7], c[5])
        return b.upload(d)
    }

    static func wedge(_ d: MTLDevice) -> GPUMesh {
        var b = Builder(inside: v(0, -0.2, 0.2))
        let bl = v(-0.5, -0.5, -0.5), br = v(0.5, -0.5, -0.5), blb = v(-0.5, -0.5, 0.5), brb = v(0.5, -0.5, 0.5)
        let tl = v(-0.5, 0.5, 0.5), tr = v(0.5, 0.5, 0.5)
        b.quad(bl, br, brb, blb); b.quad(blb, brb, tr, tl); b.quad(bl, br, tr, tl)
        b.tri(bl, blb, tl); b.tri(br, brb, tr)
        return b.upload(d)
    }

    static func cornerWedge(_ d: MTLDevice) -> GPUMesh {
        var b = Builder(inside: v(0.2, -0.25, -0.2))
        let a = v(0.5, 0.5, -0.5)
        let p0 = v(-0.5, -0.5, -0.5), p1 = v(0.5, -0.5, -0.5), p2 = v(0.5, -0.5, 0.5), p3 = v(-0.5, -0.5, 0.5)
        b.quad(p0, p1, p2, p3)
        b.tri(p1, p2, a); b.tri(p0, p1, a); b.tri(p0, p3, a); b.tri(p3, p2, a)
        return b.upload(d)
    }

    static func sphere(_ d: MTLDevice, rings: Int = 14, segs: Int = 24) -> GPUMesh {
        var b = Builder()
        func pt(_ r: Int, _ s: Int) -> SIMD3<Float> {
            let th = Float(r) * .pi / Float(rings), ph = Float(s) * 2 * .pi / Float(segs)
            return v(sin(th) * cos(ph) * 0.5, cos(th) * 0.5, sin(th) * sin(ph) * 0.5)
        }
        for r in 0..<rings {
            for s in 0..<segs {
                let a = pt(r, s), c = pt(r + 1, s), dd = pt(r + 1, s + 1), e = pt(r, s + 1)
                if r != 0 { b.smoothTri(a, simd_normalize(a), c, simd_normalize(c), e, simd_normalize(e)) }
                if r != rings - 1 { b.smoothTri(c, simd_normalize(c), dd, simd_normalize(dd), e, simd_normalize(e)) }
            }
        }
        return b.upload(d)
    }

    /// Cylinder along X, like Roblox's Cylinder part shape.
    static func cylinder(_ d: MTLDevice, segs: Int = 24, axis: Int = 0) -> GPUMesh {
        var b = Builder()
        func ring(_ i: Int) -> (Float, Float) { let a = Float(i) * 2 * .pi / Float(segs); return (cos(a) * 0.5, sin(a) * 0.5) }
        func p(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
            axis == 0 ? v(x, y, z) : (axis == 1 ? v(y, x, z) : v(y, z, x))
        }
        for i in 0..<segs {
            let (y0, z0) = ring(i), (y1, z1) = ring(i + 1)
            let n0 = simd_normalize(p(0, y0, z0)), n1 = simd_normalize(p(0, y1, z1))
            let a = p(-0.5, y0, z0), c = p(0.5, y0, z0), dd = p(0.5, y1, z1), e = p(-0.5, y1, z1)
            b.smoothTri(a, n0, c, n0, dd, n1)
            b.smoothTri(a, n0, dd, n1, e, n1)
            b.tri(p(0.5, 0, 0), p(0.5, y0, z0), p(0.5, y1, z1))
            b.tri(p(-0.5, 0, 0), p(-0.5, y1, z1), p(-0.5, y0, z0))
        }
        return b.upload(d)
    }

    /// Cone pointing +Y with its base at y = 0 (arrow heads).
    static func cone(_ d: MTLDevice, segs: Int = 16) -> GPUMesh {
        var b = Builder(inside: v(0, 0.25, 0))
        for i in 0..<segs {
            let a0 = Float(i) * 2 * .pi / Float(segs), a1 = Float(i + 1) * 2 * .pi / Float(segs)
            let p0 = v(cos(a0) * 0.5, 0, sin(a0) * 0.5), p1 = v(cos(a1) * 0.5, 0, sin(a1) * 0.5)
            b.tri(p0, p1, v(0, 1, 0))
            b.tri(v(0, 0, 0), p1, p0)
        }
        return b.upload(d)
    }

    /// Torus in the XZ plane (rotate handles). Major radius 1, minor `tube`.
    static func torus(_ d: MTLDevice, tube: Float = 0.04, segs: Int = 48, sides: Int = 8) -> GPUMesh {
        var b = Builder()
        func pt(_ i: Int, _ j: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            let u = Float(i) * 2 * .pi / Float(segs), w = Float(j) * 2 * .pi / Float(sides)
            let center = v(cos(u), 0, sin(u))
            let n = center * cos(w) + v(0, sin(w), 0)
            return (center + n * tube, n)
        }
        for i in 0..<segs {
            for j in 0..<sides {
                let (a, na) = pt(i, j), (c, nc) = pt(i + 1, j), (e, ne) = pt(i + 1, j + 1), (f, nf) = pt(i, j + 1)
                b.smoothTri(a, na, c, nc, e, ne)
                b.smoothTri(a, na, e, ne, f, nf)
            }
        }
        return b.upload(d)
    }

    /// The 12 edges of a unit cube as a line list (selection boxes). Normals are zero = unshaded.
    static func boxEdges(_ d: MTLDevice) -> GPUMesh {
        var b = Builder()
        let h: Float = 0.5
        for axis in 0..<3 {
            for s1: Float in [-h, h] {
                for s2: Float in [-h, h] {
                    var p = SIMD3<Float>(repeating: 0), q = SIMD3<Float>(repeating: 0)
                    let o1 = (axis + 1) % 3, o2 = (axis + 2) % 3
                    p[axis] = -h; q[axis] = h; p[o1] = s1; q[o1] = s1; p[o2] = s2; q[o2] = s2
                    b.vert(p, .zero); b.vert(q, .zero)
                }
            }
        }
        return b.upload(d, .line)
    }
}
