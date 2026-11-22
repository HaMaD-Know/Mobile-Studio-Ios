import SwiftUI
import StudioCore

/// Terrain Editor state and actions (port of ui/TerrainPanel.kt + the terrain parts of ViewportView).
@MainActor
final class TerrainEditor: ObservableObject {
    @Published var tool: TerrainOps.Brush?
    @Published var material = TerrainMaterials.fromName("Grass")
    @Published var radius: Float = 12
    @Published var strength: Float = 0.5
    @Published var cube = false
    @Published var generating = false
    @Published var progress: Float = 0
    /// Brush position under the finger (for the preview sphere).
    var hover: Vector3?
    var strokeOld: PropValue?
    var planeY: Float?
    var lastDab: Vector3?
}

extension StudioStore {
    /// Workspace.Terrain, created when missing.
    func terrainInstance(create: Bool = true) -> Instance? {
        if let t = model.workspace.findFirstChildOfClass("Terrain") { return t }
        guard create else { return nil }
        PlaceFactory.ensureTerrain(model.workspace)
        return model.workspace.findFirstChildOfClass("Terrain")
    }

    /// Terrain hit under a screen point.
    func terrainHit(at p: CGPoint) -> TerrainMesher.RayHit? {
        guard let t = TerrainStore.terrainOf(shownModel) else { return nil }
        let (o, d) = ray(at: p)
        return TerrainMesher.raycast(TerrainStore.of(t), origin: o, dir: d, maxDist: 4000)
    }

    /// Where a brush lands: terrain first, then parts, then the y = 0 plane.
    private func brushPoint(at p: CGPoint) -> (Vector3, Vector3)? {
        let (o, d) = ray(at: p)
        var best: (Float, Vector3, Vector3)?
        if let h = terrainHit(at: p) { best = (h.t, h.point, h.normal) }
        if let ph = Picking.cast(renderParts(), origin: o, dir: d, skipLocked: false), ph.distance < (best?.0 ?? .greatestFiniteMagnitude) {
            best = (ph.distance, ph.point, ph.normal)
        }
        if best == nil, d.y < -0.01 {
            let t = -o.y / d.y
            if t > 0 && t < 4000 { best = (t, o + d * t, .yAxis) }
        }
        return best.map { ($0.1, $0.2) }
    }

    enum StrokePhase { case began, moved, ended }

    func terrainStroke(_ phase: StrokePhase, at p: CGPoint) {
        let ed = terrainEditor
        guard let tool = ed.tool, play == nil, let t = terrainInstance() else { return }
        let g = TerrainStore.of(t)
        switch phase {
        case .began:
            ed.strokeOld = t.props["SmoothGrid"] ?? .binaryString(BinaryString(Data([1, 5])))
            ed.lastDab = nil
            if let (pt, _) = brushPoint(at: p) { ed.planeY = pt.y }
            fallthrough
        case .moved:
            guard let (pt, n) = brushPoint(at: p) else { return }
            ed.hover = pt
            // Space dabs by a third of the radius so strokes are even.
            if let last = ed.lastDab, (last - pt).magnitude < max(1, ed.radius / 3), phase == .moved { return }
            ed.lastDab = pt
            // Add / Grow build from the surface outward; Subtract digs in.
            let c: Vector3
            switch tool {
            case .add, .grow: c = pt + n * (ed.radius * 0.35)
            case .subtract, .erode: c = pt - n * (ed.radius * 0.35)
            default: c = pt
            }
            TerrainOps.brush(g, tool, center: c, radius: ed.radius, strength: ed.strength, material: ed.material,
                             cube: ed.cube, planeY: ed.planeY)
        case .ended:
            ed.hover = nil
            commitTerrain(t, label: "Terrain \(tool.rawValue)")
        }
    }

    /// Writes the grid to SmoothGrid and records one undo step for the whole stroke.
    func commitTerrain(_ t: Instance, label: String) {
        guard let (old, new) = TerrainStore.flush(t) else { terrainEditor.strokeOld = nil; return }
        session.undo.begin(label)
        session.recordProp(t, "SmoothGrid", old: terrainEditor.strokeOld ?? old, new: new)
        session.undo.commit()
        terrainEditor.strokeOld = nil
        dirty = true
    }

    func generateTerrain(_ o: TerrainGenerator.Options) {
        guard let t = terrainInstance(), !terrainEditor.generating else { return }
        let ed = terrainEditor
        ed.generating = true
        ed.progress = 0
        Task.detached(priority: .userInitiated) {
            let g = TerrainGrid()
            let n = TerrainGenerator.generate(g, o) { f in
                Task { @MainActor in ed.progress = f }
            }
            let data = g.encode()
            await MainActor.run {
                let old = t.props["SmoothGrid"] ?? .binaryString(BinaryString(Data([1, 5])))
                let new = PropValue.binaryString(BinaryString(data))
                self.session.undo.begin("Generate Terrain")
                t.set("SmoothGrid", new, notify: false)
                self.session.recordProp(t, "SmoothGrid", old: old, new: new)
                self.session.undo.commit()
                ed.generating = false
                self.dirty = true
                self.log("Generated \(n) terrain voxels")
                self.showToast("Generated terrain")
            }
        }
    }

    func clearTerrain() {
        guard let t = terrainInstance(create: false) else { return }
        terrainEditor.strokeOld = t.props["SmoothGrid"]
        TerrainStore.of(t).clear()
        commitTerrain(t, label: "Clear Terrain")
        showToast("Terrain cleared")
    }

    /// Brush preview drawn in the viewport.
    func terrainOverlay() -> [SceneRenderer.Overlay] {
        guard terrainEditor.tool != nil, let h = terrainEditor.hover else { return [] }
        let r = terrainEditor.radius
        let s = Vector3(r * 2, r * 2, r * 2)
        return [.init(mesh: terrainEditor.cube ? .cube : .sphere, model: CFrame.at(h).matrix(scale: s),
                      color: SIMD4(0.3, 0.65, 1, 0.22), onTop: false)]
    }
}
