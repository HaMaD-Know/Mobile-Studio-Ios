import MetalKit
import StudioCore

/// Draws Workspace.Terrain (port of render/TerrainView.kt): chunks are meshed on demand, cached on
/// the GPU and re-meshed when they or a neighbour change. Meshing is spread over frames so big
/// maps don't stall the viewport.
final class TerrainRenderer {
    private struct ChunkGPU {
        var stamp: Int
        var colorKey: Int
        var solid: MTLBuffer?
        var solidCount: Int
        var water: MTLBuffer?
        var waterCount: Int
        var center: Vector3
    }

    let device: MTLDevice
    private let solidPipeline: MTLRenderPipelineState
    private let waterPipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private var cache: [Int64: ChunkGPU] = [:]
    private weak var grid: TerrainGrid?
    private var seenVersion = -1
    private var seenColorKey = 0
    private var stale: [Int64: (Int, Int, Int)] = [:]
    private var waterColor = SIMD4<Float>(0.05, 0.33, 0.36, 0.3)

    /// Chunks meshed per frame once the first frame is drawn.
    var budget = 6

    init(device: MTLDevice, library lib: MTLLibrary) throws {
        self.device = device
        let sd = MTLVertexDescriptor()
        sd.attributes[0].format = .float3; sd.attributes[0].offset = 0; sd.attributes[0].bufferIndex = 0
        sd.attributes[1].format = .float3; sd.attributes[1].offset = 12; sd.attributes[1].bufferIndex = 0
        sd.attributes[2].format = .float4; sd.attributes[2].offset = 24; sd.attributes[2].bufferIndex = 0
        sd.layouts[0].stride = 40
        let wd = MTLVertexDescriptor()
        wd.attributes[0].format = .float3; wd.attributes[0].offset = 0; wd.attributes[0].bufferIndex = 0
        wd.attributes[1].format = .float3; wd.attributes[1].offset = 12; wd.attributes[1].bufferIndex = 0
        wd.layouts[0].stride = 24

        func pipe(_ vs: String, _ fs: String, _ vd: MTLVertexDescriptor, blend: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs)
            d.fragmentFunction = lib.makeFunction(name: fs)
            d.vertexDescriptor = vd
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = .depth32Float
            d.rasterSampleCount = 4
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        solidPipeline = try pipe("terrain_vs", "terrain_fs", sd, blend: false)
        waterPipeline = try pipe("water_vs", "water_fs", wd, blend: true)
        let sp = MTLRenderPipelineDescriptor()
        sp.vertexFunction = lib.makeFunction(name: "terrain_shadow_vs")
        sp.vertexDescriptor = sd
        sp.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline = try device.makeRenderPipelineState(descriptor: sp)
    }

    /// Syncs the GPU cache with the terrain of `root` (a DataModel); call once per frame.
    func update(root: Instance?, camera: Vector3) {
        guard let t = TerrainStore.terrainOf(root) else {
            if !cache.isEmpty { cache.removeAll(); stale.removeAll() }
            grid = nil
            return
        }
        let g = TerrainStore.of(t)
        let colors = TerrainMaterials.colors(t)
        var ck = 0
        for c in colors { ck = ck &* 31 &+ Color3.c8(c.r) &* 65536 &+ Color3.c8(c.g) &* 256 &+ Color3.c8(c.b) }
        if let wc = t.get("WaterColor")?.asColor3 {
            waterColor = SIMD4(wc.r, wc.g, wc.b, t.get("WaterTransparency")?.asFloat ?? 0.3)
        }
        if g !== grid { cache.removeAll(); stale.removeAll(); grid = g; seenVersion = -1 }
        if g.version != seenVersion || ck != seenColorKey {
            seenVersion = g.version
            seenColorKey = ck
            // Candidate chunks: every stored chunk plus the neighbours below/behind it, which own the
            // faces on the shared boundary.
            var want: [Int64: (Int, Int, Int)] = [:]
            for c in g.chunks.values {
                for dx in 0...1 { for dy in 0...1 { for dz in 0...1 {
                    let x = c.cx - dx, y = c.cy - dy, z = c.cz - dz
                    want[TerrainGrid.key(x, y, z)] = (x, y, z)
                } } }
            }
            for k in cache.keys where want[k] == nil { cache[k] = nil }
            stale.removeAll()
            for (k, p) in want {
                let st = TerrainMesher.stamp(g, p.0, p.1, p.2)
                if let e = cache[k], e.stamp == st, e.colorKey == ck { continue }
                stale[k] = p
            }
        }
        guard !stale.isEmpty else { return }
        // Nearest chunks first; everything on the very first pass for small maps.
        let n = cache.isEmpty && stale.count <= 48 ? stale.count : budget
        let next = stale.sorted { a, b in
            dist(a.value, camera) < dist(b.value, camera)
        }.prefix(n)
        for (k, p) in next {
            stale[k] = nil
            let m = TerrainMesher.mesh(g, p.0, p.1, p.2, colors: colors)
            var e = ChunkGPU(stamp: m.stamp, colorKey: ck, solid: nil, solidCount: 0, water: nil, waterCount: 0,
                             center: (m.min + m.max) * 0.5)
            if !m.solid.isEmpty {
                e.solid = m.solid.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
                e.solidCount = m.solidVertexCount
            }
            if !m.water.isEmpty {
                e.water = m.water.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
                e.waterCount = m.waterVertexCount
            }
            cache[k] = e
        }
    }

    private func dist(_ p: (Int, Int, Int), _ cam: Vector3) -> Float {
        let c = Vector3(Float(p.0) * 128 + 64, Float(p.1) * 128 + 64, Float(p.2) * 128 + 64)
        return (c - cam).magnitude
    }

    var hasContent: Bool { cache.values.contains { $0.solidCount > 0 || $0.waterCount > 0 } }

    func drawShadow(_ enc: MTLRenderCommandEncoder) {
        enc.setRenderPipelineState(shadowPipeline)
        for e in cache.values where e.solidCount > 0 {
            enc.setVertexBuffer(e.solid, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: e.solidCount)
        }
    }

    func drawSolid(_ enc: MTLRenderCommandEncoder) {
        enc.setRenderPipelineState(solidPipeline)
        enc.setCullMode(.none)
        for e in cache.values where e.solidCount > 0 {
            enc.setVertexBuffer(e.solid, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: e.solidCount)
        }
        enc.setCullMode(.none)
    }

    func drawWater(_ enc: MTLRenderCommandEncoder) {
        enc.setRenderPipelineState(waterPipeline)
        var wc = waterColor
        enc.setFragmentBytes(&wc, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
        for e in cache.values where e.waterCount > 0 {
            enc.setVertexBuffer(e.water, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: e.waterCount)
        }
    }
}
