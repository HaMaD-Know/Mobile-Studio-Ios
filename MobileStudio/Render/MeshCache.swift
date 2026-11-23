import MetalKit
import UIKit
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

    struct UnionSubmesh {
        let key: String
        let mesh: GPUMesh
        let style: SolidModeling.Style
    }
    private var unionCache: [ObjectIdentifier: (sig: Int64, items: [UnionSubmesh])] = [:]

    /// Submeshes for a UnionOperation / IntersectOperation built with SolidModeling.
    func unionDrawables(for op: Instance) -> (items: [UnionSubmesh], scale: Vector3)? {
        guard SolidModeling.isOperation(op), let device, let r = SolidModeling.result(op) else { return nil }
        let id = ObjectIdentifier(op)
        let sc = SolidModeling.scaleOf(op, r)
        if let e = unionCache[id], e.sig == r.sig { return (e.items, sc) }
        var items: [UnionSubmesh] = []
        for (styleIdx, verts) in r.tris.sorted(by: { $0.key < $1.key }) {
            guard !verts.isEmpty,
                  let buf = device.makeBuffer(bytes: verts, length: verts.count * 4, options: .storageModeShared) else { continue }
            let mesh = GPUMesh(buffer: buf, vertexCount: verts.count / 8, primitive: .triangle)
            let style = styleIdx >= 0 && styleIdx < r.styles.count
                ? r.styles[styleIdx]
                : SolidModeling.Style(color: PartData.color(op), transparency: PartData.transparency(op))
            items.append(UnionSubmesh(key: "csg:\(id.hashValue):\(r.sig):\(styleIdx)", mesh: mesh, style: style))
        }
        unionCache[id] = (r.sig, items)
        if unionCache.count > 128 { unionCache.removeAll() }
        return (items, sc)
    }

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

/// Textures downloaded from asset ids (MeshPart TextureID, Decals, Skyboxes...).
final class AssetTextures {
    private var textures: [String: MTLTexture] = [:]
    private var inFlight: Set<String> = []
    private var failedAt: [String: CFAbsoluteTime] = [:]
    private var loader: MTKTextureLoader?

    @MainActor
    func texture(for content: String, device: MTLDevice) -> MTLTexture? {
        let key = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if key.caseInsensitiveCompare(PlaceFactory.spawnDecalTexture) == .orderedSame {
            if let cached = textures[key] { return cached }
            if let tex = makeSpawnTexture(device: device) {
                textures[key] = tex
                return tex
            }
            return nil
        }
        if key.hasPrefix("rbxasset://") { return nil }
        guard let id = AssetCache.assetId(key) else { return nil }
        if id == 6372755229 {
            if let cached = textures[key] { return cached }
            if let tex = makeGridTexture(device: device) {
                textures[key] = tex
                return tex
            }
            return nil
        }
        if let tex = textures[key] { return tex }
        if inFlight.contains(key) { return nil }
        if let failed = failedAt[key], CFAbsoluteTimeGetCurrent() - failed < 15 { return nil }

        inFlight.insert(key)
        Task { @MainActor [weak self] in
            let bytes = await Task.detached(priority: .utility) {
                await Self.fetchImageBytes(id: id, key: key, depth: 0)
            }.value
            guard let self else { return }
            self.inFlight.remove(key)
            if let bytes, let tex = self.decodeTexture(data: bytes, device: device) {
                self.textures[key] = tex
                self.failedAt.removeValue(forKey: key)
                Instance.changeCount += 1
            } else {
                self.failedAt[key] = CFAbsoluteTimeGetCurrent()
            }
        }
        return nil
    }

    private func decodeTexture(data: Data, device: MTLDevice) -> MTLTexture? {
        if loader == nil { loader = MTKTextureLoader(device: device) }
        if let tex = try? loader?.newTexture(data: data, options: [.SRGB: false, .generateMipmaps: true]) {
            return tex
        }
        if let img = UIImage(data: data), let cg = img.cgImage {
            return try? loader?.newTexture(cgImage: cg, options: [.SRGB: false, .generateMipmaps: true])
        }
        return nil
    }

    private static var diskDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("img", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func diskURL(for id: Int64) -> URL {
        diskDir.appendingPathComponent("\(id).img")
    }

    private static func isDecodableImage(_ data: Data) -> Bool {
        UIImage(data: data) != nil
    }

    private static func unwrapImageId(from data: Data, originalId: Int64) -> Int64? {
        guard let doc = try? RbxFile.read(data) else { return nil }
        let propNames = ["Texture", "TextureId", "ShirtTemplate", "PantsTemplate", "Graphic", "ColorMap", "SkyboxFt"]
        var stack = doc.roots
        while !stack.isEmpty {
            let inst = stack.removeFirst()
            for prop in propNames {
                if let uri = inst.get(prop)?.asURI,
                   let inner = AssetCache.assetId(uri),
                   inner != originalId {
                    return inner
                }
            }
            stack.append(contentsOf: inst.children)
        }
        return nil
    }

    private static func fetchThumbnailBytes(id: Int64) async -> Data? {
        let thumbURL = "https://thumbnails.roblox.com/v1/assets?assetIds=\(id)&returnPolicy=PlaceHolder&size=420x420&format=Png&isCircular=false"
        guard let url = URL(string: thumbURL),
              let (metaData, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let list = obj["data"] as? [[String: Any]],
              let first = list.first,
              (first["state"] as? String) == "Completed",
              let imageUrlStr = first["imageUrl"] as? String,
              let imgUrl = URL(string: imageUrlStr),
              let (imgBytes, imgResp) = try? await URLSession.shared.data(from: imgUrl),
              (imgResp as? HTTPURLResponse)?.statusCode == 200,
              isDecodableImage(imgBytes) else {
            return nil
        }
        return imgBytes
    }

    private static func fetchImageBytes(id: Int64, key: String, depth: Int) async -> Data? {
        if depth > 2 { return nil }
        let cacheFile = diskURL(for: id)
        if let cached = try? Data(contentsOf: cacheFile), isDecodableImage(cached) {
            return cached
        }
        // Check local .bin cache or download raw asset (preserves full-res images & unwraps Decal/Shirt .rbxm wrappers).
        let raw: Data? = if let local = AssetCache.shared.data(for: key), !local.isEmpty {
            local
        } else {
            try? await AssetCache.shared.download(id)
        }
        if let raw, !raw.isEmpty {
            if isDecodableImage(raw) {
                try? raw.write(to: cacheFile, options: .atomic)
                return raw
            }
            if let innerId = unwrapImageId(from: raw, originalId: id),
               let nested = await fetchImageBytes(id: innerId, key: "rbxassetid://\(innerId)", depth: depth + 1) {
                try? nested.write(to: cacheFile, options: .atomic)
                return nested
            }
        }
        // Fallback to Roblox Thumbnail API (works unauthenticated and handles wrapped/TGA textures).
        if let thumb = await fetchThumbnailBytes(id: id) {
            try? thumb.write(to: cacheFile, options: .atomic)
            return thumb
        }
        return nil
    }

    private func upload(_ img: UIImage, device: MTLDevice) -> MTLTexture? {
        guard let cg = img.cgImage else { return nil }
        if loader == nil { loader = MTKTextureLoader(device: device) }
        return try? loader?.newTexture(cgImage: cg, options: [.SRGB: false, .generateMipmaps: true])
    }

    private func makeGridTexture(device: MTLDevice) -> MTLTexture? {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: fmt).image { ctx in
            let cg = ctx.cgContext
            cg.setStrokeColor(UIColor.white.cgColor)
            cg.setLineWidth(6)
            cg.stroke(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        return upload(img, device: device)
    }

    private func makeSpawnTexture(device: MTLDevice) -> MTLTexture? {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let s: CGFloat = 256
        let img = UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: fmt).image { ctx in
            let cg = ctx.cgContext
            cg.setAllowsAntialiasing(true)
            // Outer and inner target rings.
            cg.setStrokeColor(UIColor(argb: -654311425).cgColor)
            cg.setLineWidth(0.055 * s)
            cg.strokeEllipse(in: CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8))
            cg.setStrokeColor(UIColor(argb: -1862270977).cgColor)
            cg.setLineWidth(0.02 * s)
            cg.strokeEllipse(in: CGRect(x: s * 0.18, y: s * 0.18, width: s * 0.64, height: s * 0.64))
            // Classic blocky spawn figure.
            cg.setFillColor(UIColor(argb: -419430401).cgColor)
            cg.fillEllipse(in: CGRect(x: s * 0.44, y: s * 0.25, width: s * 0.12, height: s * 0.12))
            let r = s * 0.03
            let rects = [
                CGRect(x: 0.41 * s, y: 0.39 * s, width: 0.18 * s, height: 0.21 * s),
                CGRect(x: 0.33 * s, y: 0.40 * s, width: 0.065 * s, height: 0.17 * s),
                CGRect(x: 0.605 * s, y: 0.40 * s, width: 0.065 * s, height: 0.17 * s),
                CGRect(x: 0.415 * s, y: 0.61 * s, width: 0.075 * s, height: 0.14 * s),
                CGRect(x: 0.51 * s, y: 0.61 * s, width: 0.075 * s, height: 0.14 * s),
            ]
            for rect in rects {
                UIBezierPath(roundedRect: rect, cornerRadius: r).fill()
            }
        }
        return upload(img, device: device)
    }
}
