import SwiftUI
import StudioCore

/// Terrain Editor dock window (port of ui/TerrainPanel.kt): Create (generate / clear) and Edit
/// (brushes, size, strength, material).
struct TerrainPanel: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var ed: TerrainEditor
    var onClose: () -> Void
    @State private var tab = "Edit"
    @State private var mapSize = 512
    @State private var biomes: Set<TerrainGenerator.Biome> = [.water, .plains, .hills, .mountains]
    @State private var biomeSize: Double = 100
    @State private var caves = true
    @State private var seed = "618033988"
    @State private var confirmClear = false

    init(store: StudioStore, onClose: @escaping () -> Void) {
        self.store = store
        self.ed = store.terrainEditor
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(icon: "mountain.2.fill", tint: Th.play, title: "Terrain Editor", onClose: {
                ed.tool = nil
                onClose()
            })
            HStack(spacing: 0) {
                ForEach(["Create", "Edit"], id: \.self) { t in
                    Button { tab = t } label: {
                        Text(t).font(.system(size: 15)).foregroundStyle(tab == t ? Th.text : Th.dim)
                            .frame(maxWidth: .infinity).frame(height: 36)
                            .background(tab == t ? Th.panel : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Th.header)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if tab == "Create" { create } else { edit }
                }
                .padding(12)
            }
        }
        .background(Th.panel)
        .onDisappear { ed.tool = nil }
    }

    // MARK: Create

    @ViewBuilder private var create: some View {
        label("Map size")
        HStack(spacing: 6) {
            ForEach([(256, "Small"), (512, "Medium"), (1024, "Large"), (2048, "Massive")], id: \.0) { s in
                Chip(label: s.1, selected: mapSize == s.0) { mapSize = s.0 }
            }
        }
        label("Biomes")
        FlowRow(spacing: 6) {
            ForEach(TerrainGenerator.Biome.allCases) { b in
                Chip(label: b.rawValue, selected: biomes.contains(b)) {
                    if biomes.contains(b) { biomes.remove(b) } else { biomes.insert(b) }
                }
            }
        }
        label("Biome size  \(Int(biomeSize))")
        Slider(value: $biomeSize, in: 30...500).tint(Th.accent)
        StudioCheckbox(isOn: $caves, label: "Caves")
        label("Seed")
        HStack(spacing: 6) {
            TextField("", text: $seed).keyboardType(.numberPad).studioField()
            Chip(label: "Random") { seed = String(Int32.random(in: 1...Int32.max)) }
        }
        Button {
            let o = TerrainGenerator.Options(size: mapSize, seed: Int32(seed) ?? 618033988, biomes: biomes,
                                             biomeSize: Int(biomeSize), caves: caves)
            store.generateTerrain(o)
        } label: {
            HStack {
                if ed.generating { ProgressView().tint(.white) }
                Text(ed.generating ? "Generating… \(Int(ed.progress * 100))%" : "Generate")
            }
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(Th.accent, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(ed.generating || biomes.isEmpty)
        Th.border.frame(height: 1)
        Button { confirmClear = true } label: {
            Text("Clear").font(.system(size: 15)).foregroundStyle(Th.error)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(Th.hover, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .confirmationDialog("Clear Terrain", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { store.clearTerrain() }
        } message: { Text("Removes all terrain from the place. You can undo it.") }
    }

    // MARK: Edit

    static let toolIcons: [TerrainOps.Brush: String] = [
        .add: "plus.circle.fill", .subtract: "minus.circle.fill", .grow: "arrow.up.circle.fill", .erode: "arrow.down.circle.fill",
        .smooth: "water.waves", .flatten: "square.split.bottomrightquarter", .paint: "paintbrush.fill", .seaLevel: "drop.fill",
    ]

    @ViewBuilder private var edit: some View {
        label("Brush")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6)], spacing: 6) {
            ForEach(TerrainOps.Brush.allCases) { b in
                Button { ed.tool = ed.tool == b ? nil : b } label: {
                    VStack(spacing: 4) {
                        Image(systemName: Self.toolIcons[b] ?? "circle").font(.system(size: 20))
                            .foregroundStyle(ed.tool == b ? .white : Th.info)
                        Text(b.rawValue).font(.system(size: 12)).foregroundStyle(ed.tool == b ? .white : Th.text)
                    }
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(ed.tool == b ? Th.accent : Th.hover, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
        if ed.tool == nil {
            Text("Pick a brush, then drag on the viewport. Two fingers still move the camera.")
                .font(.system(size: 12)).foregroundStyle(Th.dim)
        }
        HStack(spacing: 6) {
            Chip(label: "Sphere", selected: !ed.cube) { ed.cube = false }
            Chip(label: "Cube", selected: ed.cube) { ed.cube = true }
        }
        label("Size  \(Int(ed.radius * 2)) studs")
        Slider(value: Binding(get: { Double(ed.radius) }, set: { ed.radius = Float($0) }), in: 2...64).tint(Th.accent)
        label("Strength  \(Int(ed.strength * 100))%")
        Slider(value: Binding(get: { Double(ed.strength) }, set: { ed.strength = Float($0) }), in: 0.05...1).tint(Th.accent)
        label("Material")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
            ForEach(TerrainMaterials.solid, id: \.self) { m in materialTile(m) }
        }
    }

    private func materialTile(_ m: Int) -> some View {
        let c = TerrainMaterials.colors(store.terrainInstance(create: false))[m]
        return Button { ed.material = m } label: {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b)))
                    .frame(height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(ed.material == m ? Th.accent : Th.border, lineWidth: ed.material == m ? 3 : 1))
                Text(TerrainMaterials.names[m]).font(.system(size: 10)).foregroundStyle(Th.text).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 13, weight: .semibold)).foregroundStyle(Th.dim)
    }
}
