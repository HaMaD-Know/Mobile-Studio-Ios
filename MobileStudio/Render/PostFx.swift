import Metal
import simd
import StudioCore

/// Metal post-processing pipeline (port of render/PostFx.kt):
/// renders `BloomEffect`, `BlurEffect`, `ColorCorrectionEffect`, and `SunRaysEffect`
/// found under `Lighting` or `Workspace.CurrentCamera`. Zero-overhead bypass when none are active.
final class PostFx {
    struct Params {
        var bloom: Float = 0
        var bloomSize: Float = 24
        var bloomThreshold: Float = 2
        var blur: Float = 0
        var brightness: Float = 0
        var contrast: Float = 0
        var saturation: Float = 0
        var tint = Color3(1, 1, 1)
        var rays: Float = 0
        var raysSpread: Float = 1

        var any: Bool {
            bloom > 0 || blur > 0 || rays > 0 || brightness != 0 || contrast != 0 || saturation != 0
                || tint.r < 0.999 || tint.g < 0.999 || tint.b < 0.999
        }
        var needsBright: Bool { bloom > 0 || blur > 0 || rays > 0 }
    }

    struct Uniforms {
        var params: SIMD4<Float> // x: threshold (bright) / bloom (comp), y: blur (comp), zw: blur dir
        var cc: SIMD4<Float>     // xyz: brightness, contrast, saturation
        var tint: SIMD4<Float>   // rgb: tint
        var rays: SIMD4<Float>   // xy: sunUV, z: intensity, w: spread
    }

    private let device: MTLDevice
    private let brightPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let compPipeline: MTLRenderPipelineState
    private let depthNone: MTLDepthStencilState
    private let clampSampler: MTLSamplerState

    private var width = 0
    private var height = 0
    private var sw = 0
    private var sh = 0
    private var sceneMSAA: MTLTexture?
    private var sceneColor: MTLTexture?
    private var sceneDepth: MTLTexture?
    private var smallTex: [MTLTexture?] = [nil, nil]

    var params = Params()
    private(set) var active = false

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device

        func makePipe(_ fs: String, samples: Int, depth: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "postfx_vs")
            d.fragmentFunction = library.makeFunction(name: fs)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.depthAttachmentPixelFormat = depth
            d.rasterSampleCount = samples
            return try device.makeRenderPipelineState(descriptor: d)
        }
        brightPipeline = try makePipe("postfx_bright_fs", samples: 1, depth: .invalid)
        blurPipeline = try makePipe("postfx_blur_fs", samples: 1, depth: .invalid)
        compPipeline = try makePipe("postfx_comp_fs", samples: 4, depth: .depth32Float)

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .always
        dd.isDepthWriteEnabled = false
        depthNone = device.makeDepthStencilState(descriptor: dd)!

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .notMipmapped
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        clampSampler = device.makeSamplerState(descriptor: sd)!
    }

    func read(lighting: Instance?, camera: Instance?) {
        var p = Params()
        for root in [lighting, camera].compactMap({ $0 }) {
            for child in root.children {
                if child.get("Enabled")?.asBool == false { continue }
                switch child.className {
                case "BloomEffect":
                    p.bloom = max(p.bloom, child.get("Intensity")?.asFloat ?? 1)
                    p.bloomSize = child.get("Size")?.asFloat ?? 24
                    p.bloomThreshold = child.get("Threshold")?.asFloat ?? 2
                case "BlurEffect":
                    p.blur = max(p.blur, child.get("Size")?.asFloat ?? 24)
                case "SunRaysEffect":
                    p.rays = max(p.rays, child.get("Intensity")?.asFloat ?? 0.25)
                    p.raysSpread = child.get("Spread")?.asFloat ?? 1
                case "ColorCorrectionEffect":
                    p.brightness += child.get("Brightness")?.asFloat ?? 0
                    p.contrast += child.get("Contrast")?.asFloat ?? 0
                    p.saturation += child.get("Saturation")?.asFloat ?? 0
                    if let c = child.get("TintColor")?.asColor3 {
                        p.tint = Color3(p.tint.r * c.r, p.tint.g * c.g, p.tint.b * c.b)
                    }
                default: break
                }
            }
        }
        params = p
    }

    /// Returns an offscreen render pass descriptor for the main 3D scene when any post effect is active,
    /// or `nil` to render directly to the screen.
    func begin(width w: Int, height h: Int) -> MTLRenderPassDescriptor? {
        guard params.any, w > 0, h > 0 else { active = false; return nil }
        if w != width || h != height || sceneColor == nil {
            guard allocate(width: w, height: h) else { active = false; return nil }
        }
        guard let msaa = sceneMSAA, let color = sceneColor, let depth = sceneDepth else {
            active = false; return nil
        }
        active = true
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = msaa
        rpd.colorAttachments[0].resolveTexture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .multisampleResolve
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.6, green: 0.75, blue: 0.95, alpha: 1)
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare
        rpd.depthAttachment.clearDepth = 1
        return rpd
    }

    func finish(cmd: MTLCommandBuffer, target rpd: MTLRenderPassDescriptor, sunX: Float, sunY: Float, sunVisible: Float) {
        guard active, let sceneColor, let s0 = smallTex[0], let s1 = smallTex[1] else { return }
        if params.needsBright {
            let threshold: Float
            if params.blur > 0 && params.bloom <= 0 && params.rays <= 0 {
                threshold = -1
            } else if params.bloom > 0 {
                threshold = min(0.95, max(0.2, (params.bloomThreshold - 1) * 0.18 + 0.45))
            } else {
                threshold = 0.82
            }
            var bu = Uniforms(params: SIMD4(threshold, 0, 0, 0), cc: .zero, tint: .one, rays: .zero)
            let brpd = MTLRenderPassDescriptor()
            brpd.colorAttachments[0].texture = s0
            brpd.colorAttachments[0].loadAction = .dontCare
            brpd.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: brpd) {
                enc.setRenderPipelineState(brightPipeline)
                enc.setFragmentTexture(sceneColor, index: 0)
                enc.setFragmentSamplerState(clampSampler, index: 0)
                enc.setFragmentBytes(&bu, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }

            let step: Float = (params.blur > 0 && params.bloom <= 0)
                ? min(4, max(0.5, params.blur / 12))
                : min(3, max(0.4, params.bloomSize / 24))
            for _ in 0..<2 {
                blurPass(cmd: cmd, src: s0, dst: s1, dx: step / Float(sw), dy: 0)
                blurPass(cmd: cmd, src: s1, dst: s0, dx: 0, dy: step / Float(sh))
            }
        }

        var cu = Uniforms(
            params: SIMD4(min(3, max(0, params.bloom * 0.6)), min(1, max(0, params.blur / 20)), 0, 0),
            cc: SIMD4(params.brightness, params.contrast, params.saturation, 0),
            tint: SIMD4(params.tint.r, params.tint.g, params.tint.b, 1),
            rays: SIMD4(sunX, sunY, min(2, max(0, params.rays * 2.2 * sunVisible)), min(1, max(0.05, params.raysSpread)))
        )
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(compPipeline)
            enc.setDepthStencilState(depthNone)
            enc.setFragmentTexture(sceneColor, index: 0)
            enc.setFragmentTexture(s0, index: 1)
            enc.setFragmentSamplerState(clampSampler, index: 0)
            enc.setFragmentBytes(&cu, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
    }

    private func blurPass(cmd: MTLCommandBuffer, src: MTLTexture, dst: MTLTexture, dx: Float, dy: Float) {
        var u = Uniforms(params: SIMD4(0, 0, dx, dy), cc: .zero, tint: .one, rays: .zero)
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(blurPipeline)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentSamplerState(clampSampler, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func allocate(width w: Int, height h: Int) -> Bool {
        width = w; height = h
        sw = max(w / 4, 16); sh = max(h / 4, 16)

        let msaaDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        msaaDesc.textureType = .type2DMultisample
        msaaDesc.sampleCount = 4
        msaaDesc.usage = .renderTarget
        msaaDesc.storageMode = .private

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        depthDesc.textureType = .type2DMultisample
        depthDesc.sampleCount = 4
        depthDesc.usage = .renderTarget
        depthDesc.storageMode = .private

        let smallDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: sw, height: sh, mipmapped: false)
        smallDesc.usage = [.renderTarget, .shaderRead]
        smallDesc.storageMode = .private

        sceneMSAA = device.makeTexture(descriptor: msaaDesc)
        sceneColor = device.makeTexture(descriptor: colorDesc)
        sceneDepth = device.makeTexture(descriptor: depthDesc)
        smallTex[0] = device.makeTexture(descriptor: smallDesc)
        smallTex[1] = device.makeTexture(descriptor: smallDesc)
        return sceneMSAA != nil && sceneColor != nil && sceneDepth != nil && smallTex[0] != nil && smallTex[1] != nil
    }
}
