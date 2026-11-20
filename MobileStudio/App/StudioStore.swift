import SwiftUI
import simd
import StudioCore
import StudioScript

/// App-wide editor state (the iOS counterpart of core/Studio.kt): owns the EditSession,
/// camera, active tool and file info, and adapts tree events to SwiftUI.
@MainActor
final class StudioStore: ObservableObject, TreeListener {
    enum Tool: String, CaseIterable, Identifiable {
        case select = "Select", move = "Move", scale = "Scale", rotate = "Rotate"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .move: "arrow.up.and.down.and.arrow.left.and.right"
            case .scale: "arrow.up.left.and.arrow.down.right"
            case .rotate: "arrow.triangle.2.circlepath"
            }
        }
    }

    let session: EditSession
    let camera = FlyCamera()

    @Published var tool: Tool = .move
    @Published var treeVersion = 0
    @Published var propsVersion = 0
    @Published var selection: [Instance] = []
    @Published var dirty = false
    @Published var fileURL: URL?
    @Published var fileName = "Place1"
    @Published var fileIsXml = false
    @Published var hasDocument = false
    @Published var toast: String?
    @Published var moveSnap: Float = 1
    @Published var rotSnapDegrees: Float = 15
    @Published var snapEnabled = true
    @Published var selectInsideModels = false
    @Published var output: [String] = []
    /// Running Play session (nil while editing).
    @Published var play: PlaySession?
    /// Bumped every few frames while playing so the HUD refreshes.
    @Published var hudTick = 0
    private var hudCounter = 0
    let audio = AudioEngine()
    /// On-screen fly controls: x strafe, y up/down, z forward.
    var flyInput = SIMD3<Float>(0, 0, 0)
    var flySpeed: Float = 40

    private var lastTick = CACurrentMediaTime()
    private var partsCache: [Instance] = []
    private var partsCacheStamp = -1
    private var pendingTree = false, pendingProps = false

    init() {
        session = EditSession(model: PlaceFactory.newPlace(.baseplate))
        session.onSelectionChanged = { [weak self] in
            guard let self else { return }
            self.selection = self.session.selection
            self.propsVersion += 1
        }
        session.onDirtyChanged = { [weak self] in self?.dirty = self?.session.dirty ?? false }
        session.model.addListener(self)
    }

    var model: DataModel { session.model }

    // MARK: TreeListener (coalesced to one UI refresh per runloop turn)

    nonisolated func childAdded(_ parent: Instance, _ child: Instance) { MainActor.assumeIsolated { scheduleTree() } }
    nonisolated func childRemoved(_ parent: Instance, _ child: Instance) { MainActor.assumeIsolated { scheduleTree() } }
    nonisolated func propChanged(_ inst: Instance, _ name: String) {
        MainActor.assumeIsolated {
            if name == "Name" || name == "Parent" { scheduleTree() }
            scheduleProps()
        }
    }
    private func scheduleTree() {
        guard !pendingTree else { return }
        pendingTree = true
        DispatchQueue.main.async { self.pendingTree = false; self.treeVersion += 1 }
    }
    private func scheduleProps() {
        guard !pendingProps else { return }
        pendingProps = true
        DispatchQueue.main.async { self.pendingProps = false; self.propsVersion += 1 }
    }

    func log(_ s: String) {
        output.append(s)
        if output.count > 500 { output.removeFirst(output.count - 500) }
    }
    func showToast(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in if self?.toast == s { self?.toast = nil } }
    }

    // MARK: documents

    func newPlace(_ t: PlaceFactory.Template) {
        replace(PlaceFactory.newPlace(t), url: nil, name: "Place1", xml: false)
        log("Created new place (\(t.title))")
    }

    func open(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let doc = try RbxFile.read(data)
            for w in doc.warnings { log("⚠︎ \(w)") }
            let ext = url.pathExtension.lowercased()
            if RbxFile.isPlace(doc) || ext == "rbxl" || ext == "rbxlx" {
                replace(PlaceFactory.fromDocument(doc), url: url, name: url.deletingPathExtension().lastPathComponent,
                        xml: !RbxFile.isBinary(data))
                Recents.add(url)
                log("Opened \(url.lastPathComponent)")
            } else {
                session.insertDocument(doc)
                hasDocument = true
                log("Inserted model \(url.lastPathComponent)")
            }
        } catch {
            showToast("Could not open: \(error.localizedDescription)")
            log("Error opening \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func replace(_ dm: DataModel, url: URL?, name: String, xml: Bool) {
        session.model.removeListener(self)
        session.replaceModel(dm)
        dm.addListener(self)
        fileURL = url
        fileName = name
        fileIsXml = xml
        hasDocument = true
        if let cam = dm.workspace.get("CurrentCamera")?.asInstance, let cf = cam.get("CFrame")?.asCFrame, cf != .identity {
            camera.setFrom(cf)
        } else {
            camera.pos = Vector3(0, 20, 40); camera.lookAt(.zero)
        }
        treeVersion += 1
        propsVersion += 1
    }

    /// Bytes for saving. The Android app writes binary; XML export is not ported yet, so .rbxlx
    /// sources are saved as binary .rbxl.
    func placeData() -> Data {
        if let cam = model.workspace.get("CurrentCamera")?.asInstance { cam.set("CFrame", .cframe(camera.cframe()), notify: false) }
        return session.serializePlace()
    }

    func saveInPlace() -> Bool {
        guard let url = fileURL, !fileIsXml else { return false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try placeData().write(to: url, options: .atomic)
            session.markSaved()
            showToast("Saved \(url.lastPathComponent)")
            return true
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
            return false
        }
    }

    func didExport(to url: URL) {
        fileURL = url
        fileName = url.deletingPathExtension().lastPathComponent
        fileIsXml = false
        session.markSaved()
        Recents.add(url)
        showToast("Saved \(url.lastPathComponent)")
    }

    // MARK: frame

    func tick() {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastTick, 0.1))
        lastTick = now
        if let play {
            play.viewport = Vector2(Float(viewSize.width), Float(viewSize.height))
            play.step(dt)
            hudCounter += 1
            if hudCounter % 6 == 0 { hudTick &+= 1 }
            return
        }
        if flyInput != .zero {
            let v = camera.right * flyInput.x + Vector3(0, 1, 0) * flyInput.y + camera.forward * flyInput.z
            camera.pos += v * (flySpeed * dt)
        }
    }

    /// Model currently shown: the Play copy while playing, else the edit model.
    var shownModel: DataModel { play?.dm ?? model }

    func renderParts() -> [Instance] {
        if partsCacheStamp != Instance.changeCount {
            partsCacheStamp = Instance.changeCount
            partsCache = shownModel.workspace.descendants().filter { $0.isA("BasePart") && $0.className != "Terrain" }
        }
        return partsCache
    }

    func renderCamera() -> (CFrame, Float) {
        if let play { return (play.cameraCFrame, play.fieldOfView) }
        return (camera.cframe(), camera.fov)
    }

    // MARK: Play mode

    func startPlay() {
        guard play == nil else { return }
        let session = PlaySession(editModel: model)
        session.viewport = Vector2(Float(viewSize.width), Float(viewSize.height))
        session.onOutput = { [weak self] level, line in
            switch level {
            case .info: self?.log(line)
            case .warn: self?.log("⚠︎ " + line)
            case .error: self?.log("⛔︎ " + line)
            }
        }
        session.onSound = { [weak self] sound, on in self?.audio.set(sound, playing: on) }
        session.assetLoader = { id, done in
            AssetCache.shared.fetch(id) { url in done(url.flatMap { try? Data(contentsOf: $0) }) }
        }
        play = session
        partsCacheStamp = -1
        session.start()
        log("▶︎ Play started")
    }

    func stopPlay() {
        guard let p = play else { return }
        p.stop()
        audio.stopAll()
        play = nil
        partsCacheStamp = -1
        Instance.changeCount += 1
        log("■ Play stopped")
    }

    struct Lighting { var sunDir: SIMD3<Float>; var sunColor: SIMD3<Float>; var ambient: Float }
    func lightingInfo() -> Lighting {
        let l = shownModel.findService("Lighting")
        let clock = l?.get("ClockTime")?.asFloat ?? 14
        let bright = l?.get("Brightness")?.asFloat ?? 2
        let a = (clock - 6) / 12 * .pi
        let dir = simd_normalize(SIMD3<Float>(-cos(a) * 0.75, max(sin(a), 0.08), 0.45))
        let day = max(0.25, min(1, sin(a) * 1.5 + 0.3))
        return Lighting(sunDir: dir, sunColor: SIMD3(1, 0.97, 0.9) * (0.45 + bright * 0.22) * day, ambient: 0.5 + 0.1 * day)
    }

    // MARK: selection & picking

    var viewSize = CGSize(width: 1, height: 1)

    func ray(at p: CGPoint) -> (Vector3, Vector3) {
        let r = camera.ray(x: Float(p.x), y: Float(p.y), width: Float(viewSize.width), height: Float(viewSize.height))
        return (r.origin, r.dir)
    }

    func tap(at p: CGPoint, additive: Bool) {
        let (o, d) = ray(at: p)
        guard let hit = Picking.cast(renderParts(), origin: o, dir: d) else {
            if !additive { session.select([]) }
            return
        }
        let target = Picking.selectable(for: hit.part, workspace: model.workspace, insideModels: selectInsideModels)
        if additive { session.toggleSelect(target) } else { session.select([target]) }
    }

    func focusSelection() {
        guard let b = Picking.bounds(session.selectedParts()) else { return }
        let c = (b.min + b.max) * 0.5
        camera.focus(on: c, radius: (b.max - b.min).magnitude * 0.5)
    }

    /// Point in front of the camera where new parts land (on whatever the screen centre looks at).
    func spawnPoint() -> Vector3 {
        let (o, d) = ray(at: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
        if let h = Picking.cast(renderParts(), origin: o, dir: d, skipLocked: false), h.distance < 200 {
            let p = h.point
            return Vector3(snap(p.x), p.y, snap(p.z))
        }
        let p = o + d * 20
        return Vector3(snap(p.x), max(0, p.y), snap(p.z))
    }

    func insertPart(shape: Int) {
        session.insertPart(shape: shape, at: spawnPoint())
        log("Inserted part")
    }

    func insertObject(_ cls: String) {
        let i = session.insertObject(cls, at: ClassDb.isA(cls, "BasePart") ? spawnPoint() + Vector3(0, 0.5, 0) : nil)
        log("Inserted \(i.className)")
    }

    func setProp(_ inst: Instance, _ name: String, _ v: PropValue) {
        session.undo.begin("Set \(name)")
        for target in (session.isSelected(inst) ? session.selection : [inst]) where target.className == inst.className || target === inst {
            session.setProp(target, name, v)
        }
        session.undo.commit()
    }

    func undo() { if let l = session.undo.undo() { log("Undo: \(l)") }; objectWillChange.send() }
    func redo() { if let l = session.undo.redo() { log("Redo: \(l)") }; objectWillChange.send() }

    private func snap(_ v: Float) -> Float { snapEnabled && moveSnap > 0 ? (v / moveSnap).rounded() * moveSnap : v }

    // MARK: tool handles

    enum HandleKind: Equatable { case move(axis: Int, sign: Float), scale(axis: Int, sign: Float), rotate(axis: Int) }

    struct DragState {
        var handle: HandleKind
        var parts: [Instance]
        var startCF: [CFrame]
        var startSize: [Vector3]
        var center: Vector3
        var axisDir: Vector3
        var startT: Float
        var startVec: Vector3
        var applied: Float = 0
    }
    private(set) var drag: DragState?

    private func handleBasis() -> (center: Vector3, scale: Float, axes: [Vector3], extents: Vector3)? {
        let parts = session.selectedParts()
        guard let b = Picking.bounds(parts) else { return nil }
        let center = (b.min + b.max) * 0.5
        let dist = (camera.pos - center).magnitude
        let scale = max(0.6, dist * 0.06)
        if tool == .scale, parts.count == 1 {
            let cf = PartData.cframe(parts[0])
            return (cf.position, scale, [cf.rightVector, cf.upVector, cf.backVector], PartData.size(parts[0]) * 0.5)
        }
        return (center, scale, [.xAxis, .yAxis, .zAxis], (b.max - b.min) * 0.5)
    }

    private static let axisColors: [SIMD4<Float>] = [SIMD4(0.93, 0.25, 0.25, 1), SIMD4(0.3, 0.85, 0.3, 1), SIMD4(0.25, 0.5, 1, 1)]

    private func handlePositions() -> [(HandleKind, Vector3, Vector3)] {
        guard tool != .select, let hb = handleBasis() else { return [] }
        var out: [(HandleKind, Vector3, Vector3)] = []
        for i in 0..<3 {
            let ax = hb.axes[i]
            switch tool {
            case .move:
                for s: Float in [1, -1] {
                    let base = hb.center + ax * (s * (hb.extents[i] + hb.scale * 0.4))
                    out.append((.move(axis: i, sign: s), base, base + ax * (s * hb.scale * 1.6)))
                }
            case .scale:
                for s: Float in [1, -1] {
                    let p = hb.center + ax * (s * (hb.extents[i] + hb.scale * 0.6))
                    out.append((.scale(axis: i, sign: s), p, p))
                }
            case .rotate:
                out.append((.rotate(axis: i), hb.center, hb.center))
            case .select: break
            }
        }
        return out
    }

    /// Returns the handle under a touch point, if any.
    func handle(at p: CGPoint) -> HandleKind? {
        guard let hb = handleBasis() else { return nil }
        let w = Float(viewSize.width), h = Float(viewSize.height)
        let touch = SIMD2<Float>(Float(p.x), Float(p.y))
        var best: (HandleKind, Float)?
        for (kind, a, b) in handlePositions() {
            var d: Float = .greatestFiniteMagnitude
            if case .rotate(let axis) = kind {
                // Distance to the projected ring.
                let u = hb.axes[(axis + 1) % 3], v = hb.axes[(axis + 2) % 3]
                let r = hb.extents.magnitude + hb.scale * 0.8
                for k in 0..<48 {
                    let t = Float(k) / 48 * 2 * .pi
                    if let s = camera.project(hb.center + u * (cos(t) * r) + v * (sin(t) * r), width: w, height: h) {
                        d = min(d, simd_distance(s, touch))
                    }
                }
            } else if let sa = camera.project(a, width: w, height: h), let sb = camera.project(b, width: w, height: h) {
                d = segmentDistance(touch, sa, sb)
            }
            if d < 28, d < (best?.1 ?? .greatestFiniteMagnitude) { best = (kind, d) }
        }
        return best?.0
    }

    private func segmentDistance(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let t = simd_length_squared(ab) < 1e-6 ? 0 : max(0, min(1, simd_dot(p - a, ab) / simd_length_squared(ab)))
        return simd_distance(p, a + ab * t)
    }

    func beginDrag(_ handle: HandleKind, at p: CGPoint) {
        guard let hb = handleBasis() else { return }
        let parts = session.selectedParts().filter { $0.get("Locked")?.asBool != true }
        guard !parts.isEmpty else { return }
        let (o, d) = ray(at: p)
        var axis = Vector3.yAxis, t: Float = 0, vec = Vector3.zero
        switch handle {
        case .move(let i, _), .scale(let i, _):
            axis = hb.axes[i]
            t = Picking.closestOnAxis(p0: hb.center, axis: axis, rayO: o, rayD: d) ?? 0
        case .rotate(let i):
            axis = hb.axes[i]
            if let hit = Picking.rayPlane(origin: o, dir: d, point: hb.center, normal: axis) { vec = (hit - hb.center).unit }
        }
        drag = DragState(handle: handle, parts: parts, startCF: parts.map(PartData.cframe), startSize: parts.map(PartData.size),
                         center: hb.center, axisDir: axis, startT: t, startVec: vec)
    }

    func updateDrag(at p: CGPoint) {
        guard var dr = drag else { return }
        let (o, d) = ray(at: p)
        switch dr.handle {
        case .move:
            guard let t = Picking.closestOnAxis(p0: dr.center, axis: dr.axisDir, rayO: o, rayD: d) else { return }
            let delta = snap(t - dr.startT)
            if delta == dr.applied { return }
            dr.applied = delta
            for (k, part) in dr.parts.enumerated() { part.set("CFrame", .cframe(dr.startCF[k] + dr.axisDir * delta)) }
        case .scale(let axis, let sign):
            guard let t = Picking.closestOnAxis(p0: dr.center, axis: dr.axisDir, rayO: o, rayD: d) else { return }
            let raw = (t - dr.startT) * sign
            var delta = snap(raw)
            let minSize: Float = snapEnabled && moveSnap > 0 ? moveSnap : 0.05
            let part = dr.parts[0], s0 = dr.startSize[0]
            if s0[axis] + delta < minSize { delta = minSize - s0[axis] }
            if delta == dr.applied { return }
            dr.applied = delta
            var s = s0; s[axis] += delta
            let shift = dr.startCF[0].vectorToWorld(Vector3.axis(axis)) * (delta * 0.5 * sign)
            PartData.setSize(part, s)
            part.set("CFrame", .cframe(dr.startCF[0] + shift))
        case .rotate:
            guard let hit = Picking.rayPlane(origin: o, dir: d, point: dr.center, normal: dr.axisDir) else { return }
            let v = (hit - dr.center).unit
            var ang = atan2(dr.startVec.cross(v).dot(dr.axisDir), dr.startVec.dot(v))
            if snapEnabled && rotSnapDegrees > 0 {
                let step = rotSnapDegrees * .pi / 180
                ang = (ang / step).rounded() * step
            }
            if ang == dr.applied { return }
            dr.applied = ang
            let rot = CFrame.at(dr.center) * CFrame.fromAxisAngle(dr.axisDir, ang) * CFrame.at(-dr.center)
            for (k, part) in dr.parts.enumerated() { part.set("CFrame", .cframe((rot * dr.startCF[k]).orthonormalized)) }
        }
        drag = dr
    }

    func endDrag() {
        guard let dr = drag else { return }
        drag = nil
        guard dr.applied != 0 else { return }
        session.undo.begin(dr.handle.label)
        for (k, part) in dr.parts.enumerated() {
            session.recordProp(part, "CFrame", old: .cframe(dr.startCF[k]), new: .cframe(PartData.cframe(part)))
            if case .scale = dr.handle {
                let key = part.props.contains("size") || !part.props.contains("Size") ? "size" : "Size"
                session.recordProp(part, key, old: .vector3(dr.startSize[k]), new: .vector3(PartData.size(part)))
            }
        }
        session.undo.commit()
    }

    // MARK: overlays for the renderer

    func overlays() -> [SceneRenderer.Overlay] {
        if play != nil { return [] }
        var out: [SceneRenderer.Overlay] = []
        let parts = session.selectedParts()
        let blue = SIMD4<Float>(0.05, 0.62, 1, 1)
        for p in parts.prefix(200) {
            let cf = PartData.cframe(p), s = PartData.size(p)
            let dist = max(1, (camera.pos - cf.position).magnitude)
            let th = dist * 0.0025
            if parts.count > 40 {
                out.append(.init(mesh: .boxEdges, model: cf.matrix(scale: s + Vector3(0.05, 0.05, 0.05)), color: blue, onTop: false))
                continue
            }
            // 12 thin boxes along the edges: readable outlines on a phone screen.
            for axis in 0..<3 {
                for s1: Float in [-0.5, 0.5] {
                    for s2: Float in [-0.5, 0.5] {
                        var c = Vector3.zero, sz = Vector3(th, th, th)
                        let o1 = (axis + 1) % 3, o2 = (axis + 2) % 3
                        c[o1] = s1 * s[o1]; c[o2] = s2 * s[o2]
                        sz[axis] = s[axis] + th
                        out.append(.init(mesh: .cube, model: (cf * CFrame.at(c)).matrix(scale: sz), color: blue, onTop: false))
                    }
                }
            }
        }
        guard let hb = handleBasis() else { return out }
        for (kind, a, b) in handlePositions() {
            let active = drag?.handle == kind
            switch kind {
            case .move(let i, let s):
                var col = StudioStore.axisColors[i]; if active { col = SIMD4(1, 0.85, 0.2, 1) }
                let dir = hb.axes[i] * s
                let len = (b - a).magnitude
                let basis = CFrame.lookAt(.zero, dir).rotationOnly * CFrame.rx(-.pi / 2)  // local +Y -> dir
                let shaftC = (a + b) * 0.5 - dir * (hb.scale * 0.25)
                out.append(.init(mesh: .cylinderY, model: (CFrame.at(shaftC) * basis).matrix(scale: Vector3(hb.scale * 0.12, len - hb.scale * 0.5, hb.scale * 0.12)), color: col))
                out.append(.init(mesh: .cone, model: (CFrame.at(b - dir * (hb.scale * 0.5)) * basis).matrix(scale: Vector3(hb.scale * 0.4, hb.scale * 0.6, hb.scale * 0.4)), color: col))
            case .scale(let i, _):
                var col = StudioStore.axisColors[i]; if active { col = SIMD4(1, 0.85, 0.2, 1) }
                out.append(.init(mesh: .sphere, model: CFrame.at(a).matrix(scale: Vector3(hb.scale * 0.5, hb.scale * 0.5, hb.scale * 0.5)), color: col))
            case .rotate(let i):
                var col = StudioStore.axisColors[i]; if active { col = SIMD4(1, 0.85, 0.2, 1) }
                let r = hb.extents.magnitude + hb.scale * 0.8
                // Torus mesh lies in XZ (normal +Y); orient its normal along the axis.
                let basis: CFrame = i == 1 ? .identity : (i == 0 ? .rz(.pi / 2) : .rx(.pi / 2))
                out.append(.init(mesh: .torus, model: (CFrame.at(hb.center) * basis).matrix(scale: Vector3(r, r, r)), color: col))
            }
        }
        return out
    }
}

extension StudioStore.HandleKind {
    var label: String {
        switch self { case .move: "Move"; case .scale: "Resize"; case .rotate: "Rotate" }
    }
}

/// Recently opened files (port of core/Recents.kt), kept as security-scoped bookmarks.
enum Recents {
    private static let key = "recentFiles"
    static func add(_ url: URL) {
        guard let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var list = UserDefaults.standard.array(forKey: key) as? [Data] ?? []
        list.removeAll { (try? resolve($0))?.path == url.path }
        list.insert(bm, at: 0)
        UserDefaults.standard.set(Array(list.prefix(12)), forKey: key)
    }
    static func all() -> [URL] {
        (UserDefaults.standard.array(forKey: key) as? [Data] ?? []).compactMap { try? resolve($0) }
    }
    private static func resolve(_ d: Data) throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: d, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
