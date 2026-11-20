import MetalKit
import simd
import StudioCore

/// Metal replacement for the Android GLES SceneRenderer: sky, parts (instanced, grouped by
/// shape and material texture), transparent parts, then selection boxes and tool handles on top.
final class SceneRenderer: NSObject, MTKViewDelegate {
    struct FrameUniforms {
        var viewProj: simd_float4x4
        var invViewProj: simd_float4x4
        var camPos: SIMD4<Float>
        var lightDir: SIMD4<Float>
        var sunColor: SIMD4<Float>
        var horizon: SIMD4<Float>
        var zenith: SIMD4<Float>
        var params: SIMD4<Float>
        var shadowVP: simd_float4x4
        var shadowOn: SIMD4<Float>
    }
    struct PartInstance {
        var model: simd_float4x4
        var rotation: simd_float4x4
        var color: SIMD4<Float>
        var size: SIMD4<Float>
        var surfA: SIMD4<Float>
        var surfB: SIMD4<Float>
        var mat: SIMD4<Float>
        var extra: SIMD4<Float>
    }
    struct OverlayInstance { var model: simd_float4x4; var color: SIMD4<Float> }
    struct DecalInstance { var model: simd_float4x4; var tint: SIMD4<Float>; var uv: SIMD4<Float>; var normal: SIMD4<Float> }

    enum ShapeKind: Int, CaseIterable { case box, wedge, cornerWedge, cylinder, ball }
    enum OverlayMesh { case boxEdges, cube, cone, cylinderY, torus, sphere }

    /// One overlay draw (selection outline or handle).
    struct Overlay {
        var mesh: OverlayMesh
        var model: simd_float4x4
        var color: SIMD4<Float>
        var onTop = true
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var partPipeline: MTLRenderPipelineState!
    private var partBlendPipeline: MTLRenderPipelineState!
    private var skyPipeline: MTLRenderPipelineState!
    private var overlayPipeline: MTLRenderPipelineState!
    private var shadowPipeline: MTLRenderPipelineState!
    private var shadowMap: MTLTexture!
    var shadowsEnabled = true
    private var decalPipeline: MTLRenderPipelineState!
    private var quadMesh: GPUMesh!
    private var depthWrite: MTLDepthStencilState!
    private var depthReadOnly: MTLDepthStencilState!
    private var depthNone: MTLDepthStencilState!
    private var sampler: MTLSamplerState!
    private var meshes: [ShapeKind: GPUMesh] = [:]
    private var overlayMeshes: [OverlayMesh: GPUMesh] = [:]
    private let textures = MaterialTextures()
    private let meshCache = MeshCache()
    private let textureCache = AssetTextures()
    private var whiteTex: MTLTexture!
    private var surfTex: MTLTexture?
    private let inflight = DispatchSemaphore(value: 3)
    private var ring: [MTLBuffer?] = [nil, nil, nil]
    private var ringIndex = 0
    private let start = Date()

    weak var store: StudioStore?

    init?(device: MTLDevice) {
        guard let q = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = q
        super.init()
        do { try build() } catch { print("Renderer setup failed: \(error)"); return nil }
    }

    private func build() throws {
        guard let lib = device.makeDefaultLibrary() else { throw RbxFormatError("No Metal library") }
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float2; vd.attributes[2].offset = 24; vd.attributes[2].bufferIndex = 0
        vd.layouts[0].stride = 32

        func pipe(_ vs: String, _ fs: String, blend: Bool, vertexDesc: MTLVertexDescriptor?) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs)
            d.fragmentFunction = lib.makeFunction(name: fs)
            d.vertexDescriptor = vertexDesc
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
        partPipeline = try pipe("part_vs", "part_fs", blend: false, vertexDesc: vd)
        partBlendPipeline = try pipe("part_vs", "part_fs", blend: true, vertexDesc: vd)
        skyPipeline = try pipe("sky_vs", "sky_fs", blend: false, vertexDesc: nil)
        overlayPipeline = try pipe("overlay_vs", "overlay_fs", blend: true, vertexDesc: vd)
        decalPipeline = try pipe("decal_vs", "decal_fs", blend: true, vertexDesc: vd)
        let sp = MTLRenderPipelineDescriptor()
        sp.vertexFunction = lib.makeFunction(name: "shadow_vs")
        sp.vertexDescriptor = vd
        sp.depthAttachmentPixelFormat = .depth32Float
        shadowPipeline = try device.makeRenderPipelineState(descriptor: sp)
        let sd0 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 2048, height: 2048, mipmapped: false)
        sd0.usage = [.renderTarget, .shaderRead]
        sd0.storageMode = .private
        shadowMap = device.makeTexture(descriptor: sd0)
        quadMesh = MeshFactory.quad(device)

        func depth(_ write: Bool, _ test: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = test ? .lessEqual : .always
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthWrite = depth(true, true)
        depthReadOnly = depth(false, true)
        depthNone = depth(false, false)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear
        sd.sAddressMode = .repeat; sd.tAddressMode = .repeat
        sd.maxAnisotropy = 8
        sampler = device.makeSamplerState(descriptor: sd)

        meshes[.box] = MeshFactory.cube(device)
        meshes[.wedge] = MeshFactory.wedge(device)
        meshes[.cornerWedge] = MeshFactory.cornerWedge(device)
        meshes[.cylinder] = MeshFactory.cylinder(device)
        meshes[.ball] = MeshFactory.sphere(device)
        overlayMeshes[.boxEdges] = MeshFactory.boxEdges(device)
        overlayMeshes[.cube] = meshes[.box]
        overlayMeshes[.cone] = MeshFactory.cone(device)
        overlayMeshes[.cylinderY] = MeshFactory.cylinder(device, segs: 12, axis: 1)
        overlayMeshes[.torus] = MeshFactory.torus(device)
        overlayMeshes[.sphere] = MeshFactory.sphere(device, rings: 10, segs: 16)

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        whiteTex = device.makeTexture(descriptor: td)
        let white: [UInt8] = [255, 255, 255, 255]
        whiteTex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: white, bytesPerRow: 4)
        textures.device = device
        surfTex = textures.load(path: "surfaces", ext: "png", subdir: "materials")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MARK: frame

    private func buffer(_ bytes: Int) -> MTLBuffer {
        let i = ringIndex
        if let b = ring[i], b.length >= bytes { return b }
        let b = device.makeBuffer(length: max(bytes, 64 * 1024) * 2, options: .storageModeShared)!
        ring[i] = b
        return b
    }

    func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(view) }
    }

    @MainActor
    private func drawFrame(_ view: MTKView) {
        guard let store, let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        inflight.wait()
        ringIndex = (ringIndex + 1) % 3
        store.tick()

        let w = Float(view.drawableSize.width), h = Float(view.drawableSize.height)
        let (camCF, fov) = store.renderCamera()
        let proj = simd_float4x4.perspective(fovY: fov * .pi / 180, aspect: w / max(h, 1), near: 0.1, far: 20000)
        let vp = proj * camCF.inverse.matrix()
        let lighting = store.lightingInfo()
        let frame = FrameUniforms(
            viewProj: vp, invViewProj: vp.inverse,
            camPos: SIMD4(camCF.position.simd, 1),
            lightDir: SIMD4(lighting.sunDir, 0),
            sunColor: SIMD4(lighting.sunColor, 0),
            horizon: SIMD4(0.78, 0.86, 0.96, 1), zenith: SIMD4(0.36, 0.58, 0.92, 1),
            params: SIMD4(lighting.ambient, 1.0, Float(Date().timeIntervalSince(start)), surfTex == nil ? 0 : 1),
            shadowVP: SceneRenderer.shadowMatrix(camera: camCF, sun: lighting.sunDir),
            shadowOn: SIMD4(shadowsEnabled ? 1 : 0, 0, 0, 0))

        // Build part instances, grouped by (mesh, textures) and opaque vs transparent.
        struct Group { var mesh: GPUMesh; var color: MTLTexture?; var normal: MTLTexture?; var items: [PartInstance] }
        var opaque: [String: Group] = [:], transparent: [String: Group] = [:]
        meshCache.device = device
        for p in store.renderParts() {
            let t = PartData.transparency(p)
            if t >= 0.999 { continue }
            let cf = PartData.cframe(p), size = PartData.size(p)
            let material = PartData.material(p)
            let c = PartData.color(p)
            var model = cf.matrix(scale: size)
            var meshKey: String
            var mesh: GPUMesh
            var colorTex: MTLTexture?, normalTex: MTLTexture?
            var texMode: Float = 0
            var surfaces = true
            if let custom = meshCache.drawable(for: p) {
                mesh = custom.mesh
                meshKey = custom.key
                model = custom.model(cf, size)
                surfaces = false
                if let tid = custom.texture, let tx = textureCache.texture(for: tid, device: device) {
                    colorTex = tx; texMode = 2; meshKey += "|" + tid
                }
            } else {
                let shape: ShapeKind
                switch PartData.shape(p) {
                case .ball: shape = .ball
                case .cylinder: shape = .cylinder
                case .wedge: shape = .wedge
                case .cornerWedge: shape = .cornerWedge
                case .block: shape = .box
                }
                mesh = meshes[shape]!
                meshKey = "shape\(shape.rawValue)"
            }
            if texMode == 0 {
                let tex = textures.names(for: material)
                let tx = textures.textures(for: tex.key)
                colorTex = tex.color != nil ? tx.color : nil
                normalTex = tex.normal != nil ? tx.normal : nil
                texMode = colorTex != nil ? 1 : 0
                meshKey += "|\(tex.key ?? "")"
            }
            let inst = PartInstance(
                model: model, rotation: cf.rotationOnly.matrix(),
                color: SIMD4(c.r, c.g, c.b, 1 - t), size: SIMD4(size.simd, 0),
                surfA: surfaces ? SIMD4(surf(p, "RightSurface"), surf(p, "TopSurface"), surf(p, "BackSurface"), 0) : .zero,
                surfB: surfaces ? SIMD4(surf(p, "LeftSurface"), surf(p, "BottomSurface"), surf(p, "FrontSurface"), 0) : .zero,
                mat: MaterialTextures.params(material),
                extra: SIMD4(material == 288 ? 1 : 0, texMode, 1 / 8, normalTex != nil ? 1 : 0))
            if t > 0.001 {
                transparent[meshKey, default: Group(mesh: mesh, color: colorTex, normal: normalTex, items: [])].items.append(inst)
            } else {
                opaque[meshKey, default: Group(mesh: mesh, color: colorTex, normal: normalTex, items: [])].items.append(inst)
            }
        }
        // Decals / Textures: one quad per face, grouped by image.
        var decals: [String: (MTLTexture, [DecalInstance])] = [:]
        for p in store.renderParts() where !p.children.isEmpty || p.name == "Torso" || p.name == "UpperTorso" {
            let cf = PartData.cframe(p), size = PartData.size(p)
            var faceItems = p.children.filter { $0.className == "Decal" || $0.className == "Texture" }
            // T-shirt graphic on the torso front (ShirtGraphic in the character).
            if (p.name == "Torso" || p.name == "UpperTorso"), let tee = p.parent?.findFirstChildOfClass("ShirtGraphic") {
                let d = Instance("Decal")
                d.set("Texture", tee.get("Graphic") ?? .string(""), notify: false)
                d.set("Face", .enumValue(EnumValue(5)), notify: false)
                faceItems.append(d)
            }
            for d in faceItems {
                let img = (d.get("Texture") ?? d.get("ColorMapContent"))?.description ?? ""
                guard !img.isEmpty, let tex = textureCache.texture(for: img, device: device) else { continue }
                let face = Int(d.get("Face")?.asEnum ?? 5)
                let (local, w, h) = SceneRenderer.faceFrame(face, size)
                var uv = SIMD4<Float>(1, 1, 0, 0)
                if d.className == "Texture" {
                    let su = d.get("StudsPerTileU")?.asFloat ?? 2, sv = d.get("StudsPerTileV")?.asFloat ?? 2
                    uv = SIMD4(w / max(su, 0.01), h / max(sv, 0.01), (d.get("OffsetStudsU")?.asFloat ?? 0) / max(su, 0.01), (d.get("OffsetStudsV")?.asFloat ?? 0) / max(sv, 0.01))
                }
                let col = d.get("Color3")?.asColor3 ?? Color3(1, 1, 1)
                let alpha = (1 - (d.get("Transparency")?.asFloat ?? 0)) * (1 - PartData.transparency(p))
                let world = cf * local
                decals[img, default: (tex, [])].1.append(DecalInstance(
                    model: world.matrix(scale: Vector3(w, h, 1)), tint: SIMD4(col.r, col.g, col.b, alpha), uv: uv,
                    normal: SIMD4(world.backVector.simd, 0)))
            }
        }
        let overlays = store.overlays()

        let partStride = MemoryLayout<PartInstance>.stride, ovStride = MemoryLayout<OverlayInstance>.stride
        let partCount = opaque.values.reduce(0) { $0 + $1.items.count } + transparent.values.reduce(0) { $0 + $1.items.count }
        // Every put() is 256-byte aligned, so budget one alignment pad per upload.
        let decalCount = decals.values.reduce(0) { $0 + $1.1.count }
        let uploads = 1 + opaque.count + transparent.count + overlays.count + decals.count
        let total = MemoryLayout<FrameUniforms>.stride + partCount * partStride + overlays.count * ovStride
            + decalCount * MemoryLayout<DecalInstance>.stride + uploads * 256
        let buf = buffer(total)
        var offset = 0
        func put<T>(_ arr: [T]) -> Int {
            offset = (offset + 255) & ~255
            let o = offset
            arr.withUnsafeBytes { raw in (buf.contents() + o).copyMemory(from: raw.baseAddress!, byteCount: raw.count) }
            offset += arr.count * MemoryLayout<T>.stride
            return o
        }
        let frameOffset = put([frame])

        guard let cmd = queue.makeCommandBuffer() else { inflight.signal(); return }
        // Opaque instance data is uploaded once and shared by the shadow and main passes.
        let opaqueList: [(Group, Int)] = opaque.values.filter { !$0.items.isEmpty }.map { ($0, put($0.items)) }
        if shadowsEnabled {
            let spd = MTLRenderPassDescriptor()
            spd.depthAttachment.texture = shadowMap
            spd.depthAttachment.loadAction = .clear
            spd.depthAttachment.storeAction = .store
            spd.depthAttachment.clearDepth = 1
            if let se = cmd.makeRenderCommandEncoder(descriptor: spd) {
                se.setRenderPipelineState(shadowPipeline)
                se.setDepthStencilState(depthWrite)
                se.setCullMode(.none)
                se.setVertexBuffer(buf, offset: frameOffset, index: 1)
                for (g, o) in opaqueList {
                    se.setVertexBuffer(g.mesh.buffer, offset: 0, index: 0)
                    se.setVertexBuffer(buf, offset: o, index: 2)
                    se.drawPrimitives(type: g.mesh.primitive, vertexStart: 0, vertexCount: g.mesh.vertexCount, instanceCount: g.items.count)
                }
                se.endEncoding()
            }
        }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { cmd.commit(); inflight.signal(); return }
        enc.setFragmentTexture(shadowMap, index: 3)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setVertexBuffer(buf, offset: frameOffset, index: 1)
        enc.setFragmentBuffer(buf, offset: frameOffset, index: 1)

        // Sky
        enc.setRenderPipelineState(skyPipeline)
        enc.setDepthStencilState(depthNone)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Parts
        enc.setCullMode(.none)
        func drawGroups(_ groups: [(Group, Int)]) {
            for (g, o) in groups {
                let mesh = g.mesh
                enc.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
                enc.setVertexBuffer(buf, offset: o, index: 2)
                enc.setFragmentBuffer(buf, offset: o, index: 2)
                enc.setFragmentTexture(g.color ?? whiteTex, index: 0)
                enc.setFragmentTexture(g.normal ?? whiteTex, index: 1)
                enc.setFragmentTexture(surfTex ?? whiteTex, index: 2)
                enc.drawPrimitives(type: mesh.primitive, vertexStart: 0, vertexCount: mesh.vertexCount, instanceCount: g.items.count)
            }
        }
        enc.setRenderPipelineState(partPipeline)
        enc.setDepthStencilState(depthWrite)
        drawGroups(opaqueList)
        // Decals sit 0.01 studs above the face, drawn after opaque geometry.
        enc.setRenderPipelineState(decalPipeline)
        enc.setDepthStencilState(depthReadOnly)
        for (_, (tex, items)) in decals {
            let o = put(items)
            enc.setVertexBuffer(quadMesh.buffer, offset: 0, index: 0)
            enc.setVertexBuffer(buf, offset: o, index: 2)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: items.count)
        }
        enc.setRenderPipelineState(partBlendPipeline)
        enc.setDepthStencilState(depthReadOnly)
        drawGroups(transparent.values.filter { !$0.items.isEmpty }.map { ($0, put($0.items)) })

        // Overlays: depth-tested ones first, then always-on-top.
        enc.setRenderPipelineState(overlayPipeline)
        for onTop in [false, true] {
            enc.setDepthStencilState(onTop ? depthNone : depthReadOnly)
            for o in overlays where o.onTop == onTop {
                guard let mesh = overlayMeshes[o.mesh] else { continue }
                let off = put([OverlayInstance(model: o.model, color: o.color)])
                enc.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
                enc.setVertexBuffer(buf, offset: off, index: 2)
                enc.drawPrimitives(type: mesh.primitive, vertexStart: 0, vertexCount: mesh.vertexCount, instanceCount: 1)
            }
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.addCompletedHandler { [inflight] _ in inflight.signal() }
        cmd.commit()
    }

    private func surf(_ p: Instance, _ name: String) -> Float { Float(p.get(name)?.asEnum ?? 0) }

    /// Orthographic sun projection covering ~220 studs around what the camera looks at.
    static func shadowMatrix(camera: CFrame, sun: SIMD3<Float>) -> simd_float4x4 {
        let centre = camera.position + camera.lookVector * 60
        let half: Float = 110, depth: Float = 800
        let eye = centre + Vector3(sun) * (depth / 2)
        let view = CFrame.lookAt(eye, centre, up: abs(sun.y) > 0.99 ? .zAxis : .yAxis).inverse.matrix()
        var ortho = simd_float4x4(diagonal: SIMD4(1 / half, 1 / half, -1 / depth, 1))
        ortho.columns.3 = SIMD4(0, 0, 0, 1)
        var vp = ortho * view
        // Snap to texels so shadows don't shimmer while the camera moves.
        let texel = 2 / Float(2048)
        let origin = vp * SIMD4<Float>(0, 0, 0, 1)
        vp.columns.3.x -= origin.x - (origin.x / texel).rounded() * texel
        vp.columns.3.y -= origin.y - (origin.y / texel).rounded() * texel
        return vp
    }

    /// Local frame of a part face (quad +Z = outward normal) and its width/height in studs.
    static func faceFrame(_ face: Int, _ s: Vector3) -> (CFrame, Float, Float) {
        let e: Float = 0.01
        switch face {
        case 0: return (CFrame.at(Vector3(s.x / 2 + e, 0, 0)) * .ry(.pi / 2), s.z, s.y)      // Right
        case 1: return (CFrame.at(Vector3(0, s.y / 2 + e, 0)) * .rx(-.pi / 2), s.x, s.z)     // Top
        case 2: return (CFrame.at(Vector3(0, 0, s.z / 2 + e)), s.x, s.y)                     // Back
        case 3: return (CFrame.at(Vector3(-s.x / 2 - e, 0, 0)) * .ry(-.pi / 2), s.z, s.y)    // Left
        case 4: return (CFrame.at(Vector3(0, -s.y / 2 - e, 0)) * .rx(.pi / 2), s.x, s.z)     // Bottom
        default: return (CFrame.at(Vector3(0, 0, -s.z / 2 - e)) * .ry(.pi), s.x, s.y)       // Front
        }
    }
}

/// Loads Roblox material textures bundled from the Android app's assets/materials folder
/// (port of render/MaterialTextures.kt; "modern" set, 8 studs per tile).
final class MaterialTextures {
    weak var device: MTLDevice?
    private var cache: [String: MTLTexture?] = [:]
    private lazy var loader: MTKTextureLoader? = device.map(MTKTextureLoader.init)

    static let names: [Int: String] = [
        256: "plastic", 512: "wood", 528: "woodplanks", 784: "marble", 788: "basalt", 800: "slate", 804: "crackedlava",
        816: "concrete", 820: "limestone", 832: "granite", 836: "pavement", 848: "brick", 864: "pebble", 880: "cobblestone",
        896: "rock", 912: "sandstone", 1040: "corrodedmetal", 1056: "diamondplate", 1072: "foil", 1088: "metal",
        1280: "grass", 1284: "leafygrass", 1296: "sand", 1312: "fabric", 1328: "snow", 1344: "mud", 1360: "ground",
        1376: "asphalt", 1392: "salt", 1536: "ice", 1552: "glacier", 1568: "glass", 2306: "ceramictiles",
        2307: "clayrooftiles", 2308: "roofshingles", 2311: "rubber",
    ]

    /// Per-material shading parameters (type, amount, scale, specular) from SceneRenderer.kt.
    static func params(_ m: Int) -> SIMD4<Float> {
        switch m {
        case 272: return SIMD4(0, 0, 1, 0.22)
        case 288: return SIMD4(0, 0, 1, 0)
        case 512: return SIMD4(2, 0.14, 1, 0.06)
        case 528: return SIMD4(3, 0.12, 1, 0.06)
        case 784: return SIMD4(11, 0.1, 0.25, 0.45)
        case 788: return SIMD4(13, 0.16, 0.9, 0.08)
        case 800: return SIMD4(12, 0.16, 0.35, 0.12)
        case 804: return SIMD4(14, 0.22, 0.7, 0.1)
        case 816: return SIMD4(23, 0.1, 1.4, 0.04)
        case 820: return SIMD4(5, 0.09, 0.5, 0.05)
        case 832: return SIMD4(24, 0.13, 2.5, 0.2)
        case 836: return SIMD4(16, 0.08, 4, 0.04)
        case 848: return SIMD4(4, 0.12, 1, 0.04)
        case 864: return SIMD4(13, 0.2, 2.2, 0.12)
        case 880: return SIMD4(13, 0.24, 0.8, 0.08)
        case 896: return SIMD4(5, 0.17, 0.4, 0.08)
        case 912: return SIMD4(12, 0.1, 0.8, 0.05)
        case 1040: return SIMD4(15, 0.2, 0.6, 0.3)
        case 1056: return SIMD4(6, 0.14, 1, 0.7)
        case 1072: return SIMD4(7, 0.07, 2, 0.9)
        case 1088: return SIMD4(7, 0.06, 1.5, 0.7)
        case 1280: return SIMD4(8, 0.16, 1.5, 0.04)
        case 1284: return SIMD4(8, 0.2, 1.2, 0.04)
        case 1296: return SIMD4(25, 0.08, 3, 0.04)
        case 1312: return SIMD4(9, 0.08, 4, 0.02)
        case 1328: return SIMD4(25, 0.05, 1, 0.3)
        case 1344: return SIMD4(5, 0.14, 0.6, 0.15)
        case 1360: return SIMD4(5, 0.15, 0.8, 0.03)
        case 1376: return SIMD4(22, 0.09, 4, 0.05)
        case 1392: return SIMD4(25, 0.07, 2, 0.15)
        case 1536: return SIMD4(10, 0.05, 0.3, 0.9)
        case 1552: return SIMD4(10, 0.08, 0.3, 0.8)
        case 1568: return SIMD4(0, 0, 1, 1)
        case 1584: return SIMD4(19, 0, 1, 0)
        case 2304: return SIMD4(18, 0.06, 1, 0.03)
        case 2305: return SIMD4(21, 0.12, 1, 0.01)
        case 2306: return SIMD4(16, 0.06, 2, 0.5)
        case 2307: return SIMD4(17, 0.12, 1, 0.1)
        case 2308: return SIMD4(17, 0.16, 0.7, 0.05)
        case 2309: return SIMD4(20, 0.1, 1, 0.15)
        case 2310: return SIMD4(5, 0.05, 0.4, 0.04)
        case 2311: return SIMD4(1, 0.02, 3, 0.08)
        default: return SIMD4(0, 0, 1, 0.28)
        }
    }

    /// Bundle resource names for a material's colour and normal maps (nil when not shipped).
    func names(for material: Int) -> (key: String?, color: String?, normal: String?) {
        guard let n = MaterialTextures.names[material] else { return (nil, nil, nil) }
        let c = exists("\(n)_c") ? "\(n)_c" : nil
        let nm = exists("\(n)_n") ? "\(n)_n" : nil
        return (n, c, nm)
    }

    private var existsCache: [String: Bool] = [:]
    private func exists(_ name: String) -> Bool {
        if let e = existsCache[name] { return e }
        let e = Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "materials/modern") != nil
        existsCache[name] = e
        return e
    }

    func textures(for key: String?) -> (color: MTLTexture?, normal: MTLTexture?) {
        guard let key else { return (nil, nil) }
        return (load(path: "\(key)_c", ext: "jpg", subdir: "materials/modern"),
                load(path: "\(key)_n", ext: "jpg", subdir: "materials/modern"))
    }

    func load(path: String, ext: String, subdir: String) -> MTLTexture? {
        let k = "\(subdir)/\(path).\(ext)"
        if let t = cache[k] { return t }
        var tex: MTLTexture?
        if let url = Bundle.main.url(forResource: path, withExtension: ext, subdirectory: subdir), let loader {
            tex = try? loader.newTexture(URL: url, options: [
                .SRGB: false, .generateMipmaps: true, .textureStorageMode: MTLStorageMode.private.rawValue,
            ])
        }
        cache[k] = tex
        return tex
    }
}
