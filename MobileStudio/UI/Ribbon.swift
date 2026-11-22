import SwiftUI
import StudioCore
import StudioScript

/// The ribbon under the tab bar (port of MainActivity.buildRibbon). Buttons for features the
/// iOS port doesn't have yet (Terrain editor, AI Assistant, Solid Modeling, Rig Builder) are left out.
struct RibbonView: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var dock: DockState
    @Binding var modal: EditorModal?
    @Binding var importer: ImportKind?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) { content }
                .padding(.horizontal, 4)
        }
        .frame(height: 80)
        .background(Th.ribbon.ignoresSafeArea(edges: .horizontal))
    }

    @ViewBuilder private var content: some View {
        switch dock.ribbonTab {
        case "Model": modelTab
        case "Avatar": avatarTab
        case "UI": uiTab
        case "Test": testTab
        case "View": viewTab
        case "Plugins": pluginsTab
        default: homeTab
        }
    }

    // MARK: Home

    @ViewBuilder private var homeTab: some View {
        RibbonGroup(caption: "Clipboard") {
            RibbonButton(icon: "doc.on.clipboard.fill", tint: Color(argb: -2056128), label: "Paste", enabled: store.session.hasClipboard) {
                store.session.paste()
            }
            VStack(alignment: .leading, spacing: 5) {
                RibbonSmallButton(icon: "doc.on.doc.fill", tint: Th.info, label: "Copy") { store.session.copySelection() }
                RibbonSmallButton(icon: "scissors", label: "Cut") { store.session.cutSelection() }
                RibbonSmallButton(icon: "plus.square.on.square.fill", tint: Th.info, label: "Duplicate") { store.session.duplicateSelection() }
            }
            .padding(.trailing, 6)
        }
        RibbonGroup(caption: "Tools") { toolButtons }
        RibbonGroup(caption: "Snap to Grid") { SnapControls(store: store) }
        RibbonGroup(caption: "Insert") {
            partMenu(label: "Part")
            RibbonButton(icon: "doc.text.fill", tint: Th.info, label: "Script") {
                store.insertInto("Script", fallback: "ServerScriptService")
            }
            RibbonButton(icon: "display", tint: Th.info, label: "UI") { dock.ribbonTab = "UI" }
            RibbonButton(icon: "plus.square.fill", tint: Th.play, label: "Object…") { modal = .insertObject }
            RibbonButton(icon: "briefcase.fill", tint: Th.error, label: "Toolbox", selected: dock.toolbox) { dock.toolbox.toggle() }
        }
        RibbonGroup(caption: "Edit") { editButtons }
        RibbonGroup(caption: "Test") { playButtons(here: false) }
    }

    @ViewBuilder private var toolButtons: some View {
        ForEach(StudioStore.Tool.allCases) { t in
            RibbonButton(icon: Self.toolIcon(t), tint: Self.toolTint(t), label: t.rawValue, selected: store.tool == t) { store.tool = t }
        }
    }

    static func toolIcon(_ t: StudioStore.Tool) -> String {
        switch t {
        case .select: "cursorarrow"
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .scale: "arrow.up.left.and.arrow.down.right.square"
        case .rotate: "arrow.clockwise.circle"
        }
    }
    static func toolTint(_ t: StudioStore.Tool) -> Color? {
        switch t {
        case .select: nil
        case .move: Th.error
        case .scale: Th.info
        case .rotate: Th.info
        }
    }

    @ViewBuilder private var editButtons: some View {
        RibbonButton(icon: "paintpalette.fill", tint: Th.warn, label: "Color") { modal = .colors }
        materialMenu
        RibbonButton(icon: "square.stack.3d.up.fill", tint: Th.info, label: "Group") { store.session.groupSelection() }
        RibbonButton(icon: "lock.fill", tint: Th.warn, label: "Lock") { toggleOnParts("Locked", label: "Lock") }
        RibbonButton(icon: "pin.fill", tint: Th.error, label: "Anchor") { toggleOnParts("Anchored", label: "Anchor") }
        RibbonButton(icon: "square.stack.3d.up.slash.fill", tint: Th.info, label: "Ungroup") { store.session.ungroupSelection() }
        RibbonButton(icon: "trash.fill", tint: Th.error, label: "Delete") { store.session.deleteSelection() }
        RibbonButton(icon: "scope", tint: Th.info, label: "Focus") { store.focusSelection() }
    }

    private var materialMenu: some View {
        RibbonMenu(icon: "square.grid.3x3.fill", tint: Color(argb: -5592406), label: "Material") {
            ForEach(Enums.items("Material"), id: \.1) { item in
                Button(item.0) { store.setOnSelectedParts("Material", .enumValue(EnumValue(UInt32(item.1))), label: "Material") }
            }
        }
    }

    private func toggleOnParts(_ name: String, label: String) {
        let parts = store.session.selectedParts()
        guard let first = parts.first else { store.showToast("Select a part first"); return }
        let on = !(first.get(name)?.asBool ?? false)
        store.setOnSelectedParts(name, .bool(on), label: label)
        store.showToast("\(name) \(on ? "on" : "off")")
    }

    private func partMenu(label: String) -> some View {
        RibbonMenu(icon: "cube.fill", tint: Color(argb: -3355444), label: label) {
            Button("Block", systemImage: "cube") { store.insertPart(shape: 1) }
            Button("Sphere", systemImage: "circle") { store.insertPart(shape: 0) }
            Button("Cylinder", systemImage: "cylinder") { store.insertPart(shape: 2) }
            Button("Wedge", systemImage: "triangle") { store.insertPart(shape: 3) }
            Button("Corner Wedge", systemImage: "pyramid") { store.insertPart(shape: 4) }
        }
    }

    @ViewBuilder private func playButtons(here: Bool) -> some View {
        let playing = store.play != nil
        RibbonButton(icon: playing ? "stop.fill" : "play.fill", tint: playing ? Th.stop : Th.play, label: playing ? "Stop" : "Play") {
            playing ? store.stopPlay() : store.startPlay()
        }
        if here {
            RibbonButton(icon: "play.fill", tint: Th.play, label: "Play Here", enabled: !playing) {
                store.startPlay(at: store.spawnPoint())
            }
        }
    }

    // MARK: Model

    @ViewBuilder private var modelTab: some View {
        RibbonGroup(caption: "Parts") {
            RibbonButton(icon: "cube.fill", tint: Color(argb: -3355444), label: "Block") { store.insertPart(shape: 1) }
            RibbonButton(icon: "circle.fill", tint: Color(argb: -3355444), label: "Sphere") { store.insertPart(shape: 0) }
            RibbonButton(icon: "cylinder.fill", tint: Color(argb: -3355444), label: "Cylinder") { store.insertPart(shape: 2) }
            RibbonButton(icon: "triangle.fill", tint: Color(argb: -3355444), label: "Wedge") { store.insertPart(shape: 3) }
            RibbonButton(icon: "pyramid.fill", tint: Color(argb: -3355444), label: "Corner") { store.insertPart(shape: 4) }
            RibbonButton(icon: "square.grid.3x3", tint: Color(argb: -3355444), label: "Truss") { store.insertObject("TrussPart") }
            RibbonButton(icon: "flag.fill", tint: Th.play, label: "Spawn") { store.insertObject("SpawnLocation") }
        }
        RibbonGroup(caption: "Appearance") {
            RibbonButton(icon: "paintpalette.fill", tint: Th.warn, label: "Color") { modal = .colors }
            materialMenu
            RibbonMenu(icon: "square.dashed.inset.filled", tint: Th.info, label: "Surface") {
                ForEach(Enums.items("SurfaceType"), id: \.1) { item in
                    Button(item.0) { setSurfaces(item.1) }
                }
            }
        }
        RibbonGroup(caption: "Effects") {
            insertButton("sparkles", Th.warn, "Particles", "ParticleEmitter")
            insertButton("flame.fill", Th.error, "Fire", "Fire")
            insertButton("cloud.fill", Th.dim, "Smoke", "Smoke")
            insertButton("sparkle", Th.warn, "Sparkles", "Sparkles")
            insertButton("lightbulb.fill", Color(argb: -9216), "Light", "PointLight")
            insertButton("square.dashed", Th.error, "Highlight", "Highlight")
        }
        RibbonGroup(caption: "Advanced") {
            insertButton("link", Th.info, "Weld", "WeldConstraint")
            insertButton("circle.slash", Th.error, "No Collide", "NoCollisionConstraint")
            insertButton("smallcircle.filled.circle", Th.play, "Attachment", "Attachment")
            RibbonButton(icon: "doc.text.fill", tint: Th.info, label: "Script") { store.insertInto("Script", fallback: "ServerScriptService") }
            RibbonButton(icon: "doc.text.fill", tint: Th.play, label: "LocalScript") { store.insertInto("LocalScript", fallback: "StarterPlayer") }
            RibbonButton(icon: "doc.text.fill", tint: Th.warn, label: "Module") { store.insertInto("ModuleScript", fallback: "ReplicatedStorage") }
        }
        RibbonGroup(caption: "Selection") { SelectionModeButtons(store: store) }
    }

    private func insertButton(_ icon: String, _ tint: Color, _ label: String, _ cls: String) -> some View {
        RibbonButton(icon: icon, tint: tint, label: label) { store.insertInto(cls) }
    }

    private func setSurfaces(_ v: Int) {
        for face in ["TopSurface", "BottomSurface", "FrontSurface", "BackSurface", "LeftSurface", "RightSurface"] {
            store.setOnSelectedParts(face, .enumValue(EnumValue(UInt32(v))), label: "Surface")
        }
    }

    // MARK: Avatar

    @ViewBuilder private var avatarTab: some View {
        RibbonGroup(caption: "Playtest") {
            RibbonMenu(icon: "person.crop.circle.fill", tint: Th.info, label: "Avatar") {
                Toggle("Use My Roblox Avatar", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "useMyAvatar") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "useMyAvatar") }))
                if !AccountStore.shared.isSignedIn {
                    Text("Sign in (Settings) to play as your avatar")
                }
            }
            RibbonMenu(icon: "cube.transparent.fill", tint: Color(argb: -3355444), label: "Character") {
                Button("R6") { setAvatarType(0) }
                Button("R15") { setAvatarType(1) }
                Button("Player's Choice") { setAvatarType(2) }
            }
        }
    }

    private func setAvatarType(_ v: UInt32) {
        guard let sp = store.model.findService("StarterPlayer") else { store.showToast("No StarterPlayer in this place"); return }
        store.setProp(sp, "GameSettingsAvatar", .enumValue(EnumValue(v)))
        store.showToast(v == 0 ? "Playtest as R6" : v == 1 ? "Playtest as R15" : "Playtest with the player's choice")
    }

    // MARK: UI

    @ViewBuilder private var uiTab: some View {
        RibbonGroup(caption: "Containers") {
            RibbonButton(icon: "display", tint: Th.info, label: "ScreenGui") { store.insertInto("ScreenGui", fallback: "StarterGui") }
            uiInsert("square.fill", "Frame", "Frame")
            uiInsert("scroll.fill", "Scrolling", "ScrollingFrame")
            uiInsert("square.on.square.fill", "Canvas", "CanvasGroup")
        }
        RibbonGroup(caption: "Text & Images") {
            uiInsert("textformat", "TextLabel", "TextLabel")
            uiInsert("capsule.fill", "TextButton", "TextButton")
            uiInsert("character.cursor.ibeam", "TextBox", "TextBox")
            uiInsert("photo.fill", "Image", "ImageLabel")
            uiInsert("photo.on.rectangle.angled", "ImageButton", "ImageButton")
        }
        RibbonGroup(caption: "Style") {
            uiInsert("square.dashed", "Corner", "UICorner")
            uiInsert("square", "Stroke", "UIStroke")
            uiInsert("circle.lefthalf.filled", "Gradient", "UIGradient")
            uiInsert("rectangle.inset.filled", "Padding", "UIPadding")
        }
        RibbonGroup(caption: "Layout") {
            uiInsert("list.bullet", "List", "UIListLayout")
            uiInsert("square.grid.2x2.fill", "Grid", "UIGridLayout")
            uiInsert("aspectratio.fill", "Aspect", "UIAspectRatioConstraint")
            uiInsert("plus.magnifyingglass", "Scale", "UIScale")
        }
        RibbonGroup(caption: "3D UI") {
            uiInsert("rectangle.on.rectangle", "Billboard", "BillboardGui")
            uiInsert("rectangle.portrait.on.rectangle.portrait", "SurfaceGui", "SurfaceGui")
        }
    }

    private func uiInsert(_ icon: String, _ label: String, _ cls: String) -> some View {
        RibbonButton(icon: icon, tint: Color(argb: -11751600), label: label) { store.insertInto(cls, fallback: "StarterGui") }
    }

    // MARK: Test

    @ViewBuilder private var testTab: some View {
        RibbonGroup(caption: "Play") {
            playButtons(here: true)
            RibbonButton(icon: "person.crop.circle.fill", tint: Th.info, label: "Avatar") { dock.ribbonTab = "Avatar" }
        }
        RibbonGroup(caption: "Output") {
            RibbonButton(icon: "eraser.fill", tint: Th.error, label: "Clear Output") { store.output.removeAll() }
            RibbonButton(icon: "terminal.fill", tint: Th.text, label: "Command") { dock.output = true }
        }
    }

    // MARK: View

    @ViewBuilder private var viewTab: some View {
        RibbonGroup(caption: "Windows") {
            RibbonButton(icon: "list.bullet.indent", tint: Th.warn, label: "Explorer", selected: dock.explorer) { dock.explorer.toggle() }
            RibbonButton(icon: "list.bullet.rectangle", tint: Th.info, label: "Properties", selected: dock.properties) { dock.properties.toggle() }
            RibbonButton(icon: "briefcase.fill", tint: Th.error, label: "Toolbox", selected: dock.toolbox) { dock.toolbox.toggle() }
            RibbonButton(icon: "text.alignleft", tint: Th.warn, label: "Output", selected: dock.output) { dock.output.toggle() }
            RibbonButton(icon: "viewfinder", tint: Th.info, label: "Hide All") { dock.toggleHideAll() }
            RibbonButton(icon: "rectangle.split.2x1", tint: Th.text, label: "Reset Layout") { dock.resetLayout() }
        }
        RibbonGroup(caption: "Viewport") {
            RibbonButton(icon: "sun.max.fill", tint: Color(argb: -9216), label: "Shadows", selected: store.shadows) { store.shadows.toggle() }
            RibbonButton(icon: "cube.fill", tint: Th.info, label: "Reset Cam") {
                store.camera.pos = Vector3(0, 20, 40); store.camera.lookAt(.zero)
            }
            RibbonButton(icon: "speedometer", tint: Th.text, label: "Fly \(FlySpeeds.label(store.flyMul))") {
                store.flyMul = FlySpeeds.next(store.flyMul)
            }
        }
        RibbonGroup(caption: "Studio") {
            RibbonButton(icon: "gearshape.fill", tint: Th.text, label: "Settings") { modal = .settings }
        }
    }

    // MARK: Plugins

    @ViewBuilder private var pluginsTab: some View {
        if !store.pluginButtons.isEmpty {
            RibbonGroup(caption: "Plugin") {
                ForEach(store.pluginButtons) { b in
                    RibbonButton(icon: "puzzlepiece.extension.fill", tint: Th.info, label: b.text, selected: b.active) {
                        store.pluginHost?.click(b.inst)
                    }
                }
            }
        }
        RibbonGroup(caption: "Plugins") {
            RibbonButton(icon: "folder.fill", tint: Th.warn, label: "From File") { importer = .plugin }
            RibbonButton(icon: "arrow.clockwise", tint: Th.info, label: "Reload") { store.reloadPlugins() }
        }
    }
}

/// Snap checkboxes and increments (MainActivity.snapGroup).
struct SnapControls: View {
    @ObservedObject var store: StudioStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StudioCheckbox(isOn: $store.rotSnapEnabled, label: "Rotate").frame(width: 82, alignment: .leading)
                NumberField(value: Double(store.rotSnapDegrees)) { store.rotSnapDegrees = Float(max(0, $0)) }
                    .frame(width: 64).studioField()
                Text("°").font(.system(size: 13)).foregroundStyle(Th.dim).frame(width: 34, alignment: .leading)
            }
            HStack(spacing: 6) {
                StudioCheckbox(isOn: $store.snapEnabled, label: "Move").frame(width: 82, alignment: .leading)
                NumberField(value: Double(store.moveSnap)) { store.moveSnap = Float(max(0, $0)) }
                    .frame(width: 64).studioField()
                Text("studs").font(.system(size: 13)).foregroundStyle(Th.dim).frame(width: 34, alignment: .leading)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Box / Multi / In Groups toggles (Model tab and the viewport buttons).
struct SelectionModeButtons: View {
    @ObservedObject var store: StudioStore
    var body: some View {
        RibbonButton(icon: "rectangle.dashed", tint: Th.info, label: "Box", selected: store.boxSelect) { store.toggleBoxSelect() }
        RibbonButton(icon: "plus.rectangle.on.rectangle", tint: Th.info, label: "Multi", selected: store.multiSelect) { store.toggleMultiSelect() }
        RibbonButton(icon: "square.on.square.dashed", tint: Th.info, label: "In Groups", selected: store.selectInsideModels) { store.toggleInsideModels() }
    }
}

enum FlySpeeds {
    static let steps: [Float] = [0.25, 0.5, 1, 2, 4, 8]
    static func next(_ v: Float) -> Float {
        let i = steps.firstIndex(of: v) ?? 2
        return steps[(i + 1) % steps.count]
    }
    static func label(_ v: Float) -> String { v == v.rounded() ? "x\(Int(v))" : "x" + String(format: "%g", v) }
}
