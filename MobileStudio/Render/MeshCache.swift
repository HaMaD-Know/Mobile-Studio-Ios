import MetalKit
import simd
import StudioCore

/// GPU meshes for MeshParts, SpecialMeshes and unions (port of render/MeshLoader.kt +
/// render/UnionMeshes.kt). Downloads happen in the background; parts draw as their primitive
/// shape until their mesh is ready (or if it can't be loaded).
final class MeshCache {
    struct Drawable {
        let key: String
        let mesh: GPUMesh
        let texture: String?
        /// Builds the model matrix from the part's CFrame and Size.
        let model: (CFrame, Vector3) -> simd_float4x4
    }

    private enum State { case loading, failed, ready(GPUMesh, SIMD3<Float>, SIMD3<Float>) }
    private var states: [String: State] = [:]
    weak var device: MTLDevice?

    private var clothes: [String: GPUMesh] = [:]

    /// R6 body parts wearing a Shirt / Pants draw with the clothing template.
    private func clothing(for p: Instance) -> Drawable? {
        guard let ch = p.parent, ch.isA("Model"), let device else { return nil }
        let shirt = ch.findFirstChildOfClass("Shirt")?.get("ShirtTemplate")?.description
        let pants = ch.findFirstChildOfClass("Pants")?.get("PantsTemplate")?.description
        let (key, tex): (String, String?)
        switch p.name {
        case "Torso": (key, tex) = ("torso", shirt ?? pants)
        case "Left Arm": (key, tex) = ("left", shirt)
        case "Right Arm": (key, tex) = ("right", shirt)
        case "Left Leg": (key, tex) = ("left", pants)
        case "Right Leg": (key, tex) = ("right", pants)
        default: return nil
        }
        guard let tex, !tex.isEmpty else { return nil }
        let mesh = clothes[key] ?? {
            let m = MeshFactory.clothedBox(device, key == "torso" ? MeshFactory.torsoRegions : MeshFactory.limbRegions(right: key == "right"))
            clothes[key] = m
            return m
        }()
        return Drawable(key: "clothes:" + key, mesh: mesh, texture: tex) { cf, size in cf.matrix(scale: size) }
    }

    func drawable(for p: Instance) -> Drawable? {
        if let c = clothing(for: p) { return c }
        if p.className == "MeshPart" {
            guard let id = PartData.meshContent(p), let r = ready("mesh:" + id, fetch: { AssetCache.shared.data(for: id) }, start: { done in
                AssetCache.shared.fetch(id) { url in done(url != nil) }
            }, parse: { try MeshFile.parse($0) }) else { return nil }
            let (mesh, mn, mx) = r
            let tex = PartData.textureContent(p)
            return Drawable(key: "mesh:" + id, mesh: mesh, texture: tex) { cf, size in cf.matrix(scale: size) * Self.normalize(mn, mx) }
        }
        if p.isA("PartOperation") && p.className != "NegateOperation" && !p.children.contains(where: { $0.isA("BasePart") }) {
            if let inline = CsgMesh.inlineData(p) {
                let key = "union:\(inline.count):\(inline.hashValue)"
                guard let r = ready(key, fetch: { inline }, start: { $0(true) }, parse: { try CsgMesh.decode($0) }) else { return nil }
                let (mesh, mn, mx) = r
                return Drawable(key: key, mesh: mesh, texture: nil) { cf, size in cf.matrix(scale: size) * Self.normalize(mn, mx) }
            }
            if let asset = p.get("AssetId")?.description, AssetCache.assetId(asset) != nil {
                let key = "unionasset:" + asset
                guard let r = ready(key, fetch: { AssetCache.shared.data(for: asset) }, start: { done in
                    AssetCache.shared.fetch(asset) { url in done(url != nil) }
                }, parse: { try CsgMesh.decode(try CsgMesh.fromAsset($0)) }) else { return nil }
                let (mesh, mn, mx) = r
                return Drawable(key: key, mesh: mesh, texture: nil) { cf, size in cf.matrix(scale: size) * Self.normalize(mn, mx) }
            }
            return nil
        }
        if let sm = p.children.first(where: { $0.className == "SpecialMesh" }) {
            let type = sm.get("MeshType")?.asEnum ?? 6
            let scale = sm.get("Scale")?.asVector3 ?? .one
            let offset = sm.get("Offset")?.asVector3 ?? .zero
            guard type == 5, let id = PartData.meshContent(sm) else { return nil }   // FileMesh only; others use primitive shapes
            guard let r = ready("mesh:" + id, fetch: { AssetCache.shared.data(for: id) }, start: { done in
                AssetCache.shared.fetch(id) { url in done(url != nil) }
            }, parse: { try MeshFile.parse($0) }) else { return nil }
            let mesh = r.0
            let tex = PartData.textureContent(sm)
            return Drawable(key: "mesh:" + id, mesh: mesh, texture: tex) { cf, _ in (cf * CFrame.at(offset)).matrix(scale: scale) }
        }
        return nil
    }

    /// Map a mesh's bounding box onto the unit cube (-0.5...0.5), like a part shape.
    static func normalize(_ mn: SIMD3<Float>, _ mx: SIMD3<Float>) -> simd_float4x4 {
        let ext = simd_max(mx - mn, SIMD3(repeating: 1e-4)), c = (mn + mx) / 2
        let s = simd_float4x4(diagonal: SIMD4(1 / ext.x, 1 / ext.y, 1 / ext.z, 1))
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4(-c.x, -c.y, -c.z, 1)
        return s * t
    }

    private func ready(_ key: String, fetch: @escaping () -> Data?, start: (@escaping (Bool) -> Void) -> Void,
                       parse: @escaping (Data) throws -> MeshData) -> (GPUMesh, SIMD3<Float>, SIMD3<Float>)? {
        switch states[key] {
        case .ready(let m, let a, let b)?: return (m, a, b)
        case .loading?, .failed?: return nil
        case nil: break
        }
        states[key] = .loading
        start { [weak self] ok in
            guard let self else { return }
            guard ok, let data = fetch() else { self.states[key] = .failed; return }
            Task.detached {
                let parsed = try? parse(data)
                await MainActor.run {
                    guard let parsed, let device = self.device, let gpu = MeshFactory.upload(device, parsed) else {
                        self.states[key] = .failed; return
                    }
                    self.states[key] = .ready(gpu, SIMD3(parsed.min[0], parsed.min[1], parsed.min[2]), SIMD3(parsed.max[0], parsed.max[1], parsed.max[2]))
                    Instance.changeCount += 1
                }
            }
        }
        return nil
    }
}

/// Textures downloaded from asset ids (MeshPart TextureID, Decals...).
final class AssetTextures {
    private var cache: [String: MTLTexture?] = [:]
    private var loader: MTKTextureLoader?

    func texture(for content: String, device: MTLDevice) -> MTLTexture? {
        if let t = cache[content] { return t }
        guard let data = AssetCache.shared.data(for: content) else {
            cache[content] = nil
            AssetCache.shared.fetch(content) { [weak self] url in
                if url != nil { self?.cache.removeValue(forKey: content); Instance.changeCount += 1 }
            }
            cache[content] = .some(nil)
            return nil
        }
        if loader == nil { loader = MTKTextureLoader(device: device) }
        let tex = try? loader?.newTexture(data: data, options: [.SRGB: false, .generateMipmaps: true])
        cache[content] = tex
        return tex
    }
}
