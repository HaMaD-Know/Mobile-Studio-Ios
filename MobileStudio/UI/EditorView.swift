import SwiftUI
import UniformTypeIdentifiers
import StudioCore
import StudioScript

extension UTType {
    static let rbxl = UTType(importedAs: "com.exampletest.mobilestudio.rbxl", conformingTo: .data)
    static let rbxlx = UTType(importedAs: "com.exampletest.mobilestudio.rbxlx", conformingTo: .xml)
    static let rbxm = UTType(importedAs: "com.exampletest.mobilestudio.rbxm", conformingTo: .data)
    static let rbxmx = UTType(importedAs: "com.exampletest.mobilestudio.rbxmx", conformingTo: .xml)
    static let robloxFiles: [UTType] = [.rbxl, .rbxlx, .rbxm, .rbxmx, .data]
}

/// Wrapper so .fileExporter can write place/model bytes.
struct BinaryFile: FileDocument {
    static var readableContentTypes: [UTType] { [.rbxl, .rbxm] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Which dock windows are open, their sizes and the ribbon tab (MainActivity's layoutPrefs).
final class DockState: ObservableObject {
    private static let d = UserDefaults.standard
    private static func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: "dock." + k) as? Bool ?? def }
    private static func n(_ k: String, _ def: Double) -> Double { d.object(forKey: "dock." + k) as? Double ?? def }

    @Published var explorer = DockState.b("explorer", true) { didSet { Self.d.set(explorer, forKey: "dock.explorer") } }
    @Published var properties = DockState.b("properties", true) { didSet { Self.d.set(properties, forKey: "dock.properties") } }
    @Published var toolbox = DockState.b("toolbox", false) { didSet { Self.d.set(toolbox, forKey: "dock.toolbox") } }
    @Published var output = DockState.b("output", false) { didSet { Self.d.set(output, forKey: "dock.output") } }
    @Published var terrain = DockState.b("terrain", false) { didSet { Self.d.set(terrain, forKey: "dock.terrain") } }
    @Published var assistant = DockState.b("assistant", false) { didSet { Self.d.set(assistant, forKey: "dock.assistant") } }
    @Published var rightW = DockState.n("rightW", 300) { didSet { Self.d.set(rightW, forKey: "dock.rightW") } }
    @Published var leftW = DockState.n("leftW", 260) { didSet { Self.d.set(leftW, forKey: "dock.leftW") } }
    @Published var rightSplit = DockState.n("rightSplit", 0.45) { didSet { Self.d.set(rightSplit, forKey: "dock.rightSplit") } }
    @Published var outSplit = DockState.n("outSplit", 0.6) { didSet { Self.d.set(outSplit, forKey: "dock.outSplit") } }
    @Published var ribbonTab = UserDefaults.standard.string(forKey: "ribbonTab") ?? "Home" {
        didSet { Self.d.set(ribbonTab, forKey: "ribbonTab") }
    }
    private var beforeHide: [Bool]?

    var allHidden: Bool { !explorer && !properties && !toolbox && !output && !terrain && !assistant }

    func toggleHideAll() {
        if allHidden, let b = beforeHide {
            explorer = b[0]; properties = b[1]; toolbox = b[2]; output = b[3]; terrain = b[4]; assistant = b[5]
            beforeHide = nil
        } else if allHidden {
            explorer = true; properties = true
        } else {
            beforeHide = [explorer, properties, toolbox, output, terrain, assistant]
            explorer = false; properties = false; toolbox = false; output = false; terrain = false; assistant = false
        }
    }

    func resetLayout() {
        explorer = true; properties = true; toolbox = false; output = false; terrain = false; assistant = false
        rightW = 300; leftW = 260; rightSplit = 0.45; outSplit = 0.6
        beforeHide = nil
    }
}

enum EditorModal: String, Identifiable {
    case insertObject, settings, cloudOpen, cloudPublish, colors, about
    case rigBuilder, gameSettings, playtestAvatar, customCharacter
    var id: String { rawValue }
}

enum ImportKind { case place, model, plugin }

/// Main editing screen (port of MainActivity.buildUi + ui/DockLayout.kt): tab bar, ribbon,
/// document tabs over the viewport / script editor, and dock windows around it.
struct EditorView: View {
    @ObservedObject var store: StudioStore
    @StateObject private var dock = DockState()
    @State private var showFileMenu = false
    @State private var modal: EditorModal?
    @State private var importer: ImportKind?
    @State private var exporting: BinaryFile?
    @State private var exportName = "Place1"
    @State private var exportType: UTType = .rbxl
    @State private var pendingDiscard: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            TopBar(store: store, dock: dock, showFileMenu: $showFileMenu, modal: $modal)
            RibbonView(store: store, dock: dock, modal: $modal, importer: $importer)
            Th.border.frame(height: 1)
            GeometryReader { geo in
                DockArea(store: store, dock: dock, size: geo.size, modal: $modal)
            }
        }
        .background(Th.bg.ignoresSafeArea())
        .overlay(alignment: .topLeading) {
            if showFileMenu {
                FileMenu(store: store, close: { showFileMenu = false }, run: fileAction)
            }
        }
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                ToastView(text: t).padding(.bottom, 24).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.toast)
        .sheet(item: $modal) { which in modalView(which) }
        .fileImporter(isPresented: Binding(get: { importer != nil }, set: { if !$0 { importer = nil } }),
                      allowedContentTypes: importer == .plugin ? [.item] : UTType.robloxFiles) { r in
            guard case .success(let url) = r else { return }
            if importer == .plugin { store.importPlugin(url) } else { store.open(url) }
            importer = nil
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting, contentType: exportType, defaultFilename: exportName) { r in
            switch r {
            case .success(let url): if exportType == .rbxl { store.didExport(to: url) } else { store.showToast("Exported \(url.lastPathComponent)") }
            case .failure(let e): store.showToast("Export failed: \(e.localizedDescription)")
            }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
                            titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { pendingDiscard?(); pendingDiscard = nil }
        } message: { Text("The current place has unsaved changes.") }
    }

    @ViewBuilder private func modalView(_ which: EditorModal) -> some View {
        switch which {
        case .insertObject: InsertObjectView { store.insertInto($0) }
        case .settings: SettingsView(store: store)
        case .cloudOpen: CloudPlacesView(store: store, mode: .open)
        case .cloudPublish: CloudPlacesView(store: store, mode: .publish)
        case .colors: BrickColorPalette { c in store.setOnSelectedParts("Color3uint8", .color3(c), label: "Color") }
        case .about: AboutView()
        case .rigBuilder: RigBuilderView(store: store)
        case .gameSettings: GameSettingsView(store: store)
        case .playtestAvatar:
            PlaytestAvatarView(store: store,
                               onOpenGameSettings: { DispatchQueue.main.async { modal = .gameSettings } },
                               onOpenCustomCharacter: { DispatchQueue.main.async { modal = .customCharacter } })
        case .customCharacter: CustomCharacterView(store: store)
        }
    }

    private func confirmDiscard(_ then: @escaping () -> Void) {
        if store.dirty { pendingDiscard = then } else { then() }
    }

    private func fileAction(_ a: FileMenu.Action) {
        showFileMenu = false
        switch a {
        case .home: store.commitScripts(); store.showStart = true
        case .newPlace(let t): confirmDiscard { store.newPlace(t) }
        case .open: confirmDiscard { importer = .place }
        case .openCloud: confirmDiscard { modal = .cloudOpen }
        case .save: if !store.saveInPlace() { saveAs() }
        case .saveAs: saveAs()
        case .publish: publish()
        case .publishAs: modal = .cloudPublish
        case .exportSelection:
            guard !store.selection.isEmpty else { store.showToast("Select something to export"); return }
            exportType = .rbxm
            exportName = store.selection.first?.name ?? "Model"
            exporting = BinaryFile(data: store.session.serializeSelection())
        case .insertModel: importer = .model
        case .settings: modal = .settings
        case .about: modal = .about
        case .close: confirmDiscard { store.hasDocument = false }
        }
    }

    private func saveAs() {
        exportType = .rbxl
        exportName = store.fileName
        exporting = BinaryFile(data: store.placeData())
    }

    private func publish() {
        guard let cloud = store.cloudPlace else { modal = .cloudPublish; return }
        Task {
            do {
                let v = try await RobloxWeb.publish(universe: cloud.0, place: cloud.1, bytes: store.placeData(), publish: true)
                store.showToast("Published (" + v + ")")
            } catch { store.showToast(error.localizedDescription) }
        }
    }
}

// MARK: - Top bar

/// File button, ribbon tabs, hide-windows, undo/redo, Play/Stop and the account chip.
struct TopBar: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var dock: DockState
    @ObservedObject var account = AccountStore.shared
    @Binding var showFileMenu: Bool
    @Binding var modal: EditorModal?

    static let tabs = ["Home", "Model", "Avatar", "UI", "Test", "View", "Plugins"]

    var body: some View {
        HStack(spacing: 0) {
            Button { showFileMenu.toggle() } label: {
                Text("File").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Th.accent, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Self.tabs, id: \.self) { t in tabButton(t) }
                }
            }
            PanelIconButton(icon: "viewfinder", tint: Th.info) { withAnimation(.easeInOut(duration: 0.15)) { dock.toggleHideAll() } }
            PanelIconButton(icon: "arrow.uturn.backward") { store.undo() }
                .disabled(!store.session.undo.canUndo).opacity(store.session.undo.canUndo ? 1 : 0.4)
            PanelIconButton(icon: "arrow.uturn.forward") { store.redo() }
                .disabled(!store.session.undo.canRedo).opacity(store.session.undo.canRedo ? 1 : 0.4)
            playButton.padding(.horizontal, 6)
            accountChip.padding(.trailing, 6)
        }
        .frame(height: 40)
        .background(Th.topbar.ignoresSafeArea(edges: [.top, .horizontal]))
    }

    private func tabButton(_ t: String) -> some View {
        let on = t == dock.ribbonTab
        return Button { dock.ribbonTab = t } label: {
            Text(t).font(.system(size: 15, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Th.text : Th.dim)
                .padding(.horizontal, 12).frame(height: 40)
                .background(on ? Th.ribbon : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var playButton: some View {
        let playing = store.play != nil
        return Button { playing ? store.stopPlay() : store.startPlay() } label: {
            HStack(spacing: 6) {
                Image(systemName: playing ? "stop.fill" : "play.fill")
                    .foregroundStyle(playing ? Color.white : Color(argb: -6226016))
                Text(playing ? "Stop" : "Play").foregroundStyle(.white)
            }
            .font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 12).frame(height: 32)
            .background(playing ? Th.stop : Th.play, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private var accountChip: some View {
        Menu {
            if account.isSignedIn {
                Text("Signed in as \(account.userName ?? "Roblox user")")
            } else {
                Text("Guest")
            }
            Button("Studio Settings…", systemImage: "gearshape") { modal = .settings }
        } label: {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 24))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Th.info)
                .frame(width: 32, height: 32)
                .background(Th.hover, in: Circle())
        }
    }
}

// MARK: - File menu

struct FileMenu: View {
    enum Action {
        case home, newPlace(PlaceFactory.Template), open, openCloud, save, saveAs, publish, publishAs
        case exportSelection, insertModel, settings, about, close
    }
    @ObservedObject var store: StudioStore
    let close: () -> Void
    let run: (Action) -> Void
    @State private var showTemplates = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.001).ignoresSafeArea().onTapGesture(perform: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    row("Home (Start Page)") { run(.home) }
                    row(showTemplates ? "New Place ▾" : "New Place ▸") { withAnimation { showTemplates.toggle() } }
                    if showTemplates {
                        ForEach(PlaceFactory.Template.allCases) { t in
                            row("      " + t.title) { run(.newPlace(t)) }
                        }
                    }
                    row("Open File… (.rbxl / .rbxm)") { run(.open) }
                    row("Open from Roblox (My Games)…") { run(.openCloud) }
                    row("Save") { run(.save) }
                    row("Save As…") { run(.saveAs) }
                    row("Publish to Roblox…") { run(.publish) }
                    row("Publish to Roblox As…") { run(.publishAs) }
                    row("Export Selection…") { run(.exportSelection) }
                    row("Insert Model File…") { run(.insertModel) }
                    row("Studio Settings…") { run(.settings) }
                    row("About Mobile Studio") { run(.about) }
                    row("Close Place") { run(.close) }
                }
            }
            .frame(width: 320)
            .frame(maxHeight: 520)
            .background(Th.header)
            .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
            .padding(.leading, 6)
            .padding(.top, 40)
        }
    }

    private func row(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 16)).foregroundStyle(Th.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dock

/// Left dock (Toolbox), centre (document tabs + viewport/script, Output under it) and right dock
/// (Explorer over Properties). On narrow screens the Toolbox slides over the centre instead.
struct DockArea: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var dock: DockState
    let size: CGSize
    @Binding var modal: EditorModal?

    private var narrow: Bool { size.width < 700 }
    private var showRight: Bool { dock.explorer || dock.properties }
    private var showLeft: Bool { dock.toolbox || dock.terrain || dock.assistant }

    @ViewBuilder private var leftDock: some View {
        VStack(spacing: 0) {
            if dock.terrain { TerrainPanel(store: store, onClose: { dock.terrain = false }) }
            if dock.terrain && (dock.toolbox || dock.assistant) { Th.border.frame(height: 2) }
            if dock.assistant { AssistantPanel(store: store, onClose: { dock.assistant = false }) }
            if dock.assistant && dock.toolbox { Th.border.frame(height: 2) }
            if dock.toolbox { ToolboxPanel(store: store, onClose: { dock.toolbox = false }) }
        }
        .background(Th.panel)
    }

    var body: some View {
        HStack(spacing: 0) {
            if showLeft && !narrow {
                leftDock
                    .frame(width: CGFloat(min(dock.leftW, Double(size.width) * 0.4)))
                VSplitter(width: $dock.leftW, growsLeft: false, range: 200...520)
            }
            centre
                .overlay(alignment: .leading) {
                    if showLeft && narrow {
                        leftDock
                            .frame(width: min(size.width * 0.85, 360))
                            .shadow(color: .black.opacity(0.4), radius: 8)
                            .transition(.move(edge: .leading))
                    }
                }
            if showRight {
                VSplitter(width: $dock.rightW, growsLeft: true, range: 200...560)
                rightDock
                    .frame(width: narrow ? size.width * 0.5 : CGFloat(min(dock.rightW, Double(size.width) * 0.45)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showLeft)
    }

    private var centre: some View {
        VStack(spacing: 0) {
            if !store.openScripts.isEmpty { DocumentTabs(store: store) }
            GeometryReader { g in
                VStack(spacing: 0) {
                    ZStack {
                        ViewportArea(store: store, paused: store.activeScript != nil)
                        if let s = store.activeScript {
                            ScriptDocView(store: store, script: s).id(ObjectIdentifier(s))
                        }
                    }
                    .frame(height: dock.output ? g.size.height * dock.outSplit : g.size.height)
                    if dock.output {
                        HSplitter(fraction: $dock.outSplit, total: g.size.height)
                        OutputPanel(store: store, onClose: { dock.output = false })
                    }
                }
            }
        }
    }

    private var rightDock: some View {
        GeometryReader { g in
            VStack(spacing: 0) {
                if dock.explorer {
                    ExplorerView(store: store, onClose: { dock.explorer = false }, onInsert: { modal = .insertObject })
                        .frame(height: dock.properties ? g.size.height * dock.rightSplit : g.size.height)
                }
                if dock.explorer && dock.properties {
                    HSplitter(fraction: $dock.rightSplit, total: g.size.height)
                }
                if dock.properties {
                    PropertiesView(store: store, onClose: { dock.properties = false })
                }
            }
        }
        .background(Th.panel)
    }
}

/// "Place1 | Script ×" strip shown once a script is open.
struct DocumentTabs: View {
    @ObservedObject var store: StudioStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                tab(icon: "photo.fill", tint: Color(argb: -11751600), title: store.fileName, active: store.activeScript == nil,
                    select: { store.showPlace() }, close: nil)
                ForEach(Array(store.openScripts.enumerated()), id: \.offset) { _, s in
                    tab(icon: ClassIcon.symbol(s.className), tint: ClassIcon.tint(s.className), title: s.name,
                        active: store.activeScript === s, select: { store.openScript(s) }, close: { store.closeScript(s) })
                }
            }
        }
        .frame(height: 38)
        .background(Th.topbar)
    }

    private func tab(icon: String, tint: Color, title: String, active: Bool, select: @escaping () -> Void, close: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
            Text(title).font(.system(size: 15)).foregroundStyle(active ? Th.text : Th.dim).lineLimit(1)
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).foregroundStyle(Th.text)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).frame(height: 38)
        .background(active ? Th.panel : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

/// The 3D view with its on-screen controls (edit mode) or the Play HUD.
struct ViewportArea: View {
    @ObservedObject var store: StudioStore
    var paused: Bool

    var body: some View {
        ZStack {
            ViewportView(store: store, paused: paused)
            if let play = store.play {
                PlayGuiView(store: store, play: play)
                PlayHUD(store: store, play: play)
            } else {
                EditControls(store: store)
                BoxSelectOverlay()
            }
        }
        .overlay(alignment: .topTrailing) { if store.play == nil { PluginWidgetsView(store: store) } }
        .overlay(alignment: .bottomTrailing) { FPSLabel().padding(8) }
        .clipped()
    }
}

// MARK: - Output

/// Output window with the command bar (port of ui/OutputPanel.kt).
struct OutputPanel: View {
    @ObservedObject var store: StudioStore
    var onClose: () -> Void
    @State private var command = ""
    @State private var history: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(icon: "text.alignleft", tint: Th.warn, title: "Output", onClose: onClose) {
                PanelIconButton(icon: "eraser.fill", tint: Th.error) { store.output.removeAll() }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.output) { line in
                            Text(line.time + "  " + line.text)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(color(line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .onChange(of: store.output.count) { _, _ in
                    if let last = store.output.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .background(Th.panel)
            HStack(spacing: 4) {
                TextField("", text: $command, prompt: Text("Run a command (Lua)").foregroundStyle(Th.dim))
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(run)
                    .studioField()
                PanelIconButton(icon: "arrow.left") { if let h = history.last { command = h } }
                PanelIconButton(icon: "play.fill", tint: Th.play, action: run)
            }
            .padding(4)
            .background(Th.header)
        }
    }

    private func run() {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        history.append(c)
        store.runCommand(c)
        command = ""
    }

    private func color(_ k: OutputLine.Kind) -> Color {
        switch k {
        case .print: Th.text
        case .info: Th.info
        case .warn: Th.warn
        case .error: Th.error
        }
    }
}

// MARK: - Small dialogs

/// BrickColor swatches for the ribbon's Color button.
struct BrickColorPalette: View {
    var onPick: (Color3) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 6)], spacing: 6) {
                    ForEach(BrickColors.all, id: \.self) { n in
                        let c = BrickColorV(Int32(n)).color
                        Button { onPick(c); dismiss() } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b)))
                                .frame(height: 40)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Th.border))
                        }
                        .accessibilityLabel(BrickColors.name(n))
                    }
                }
                .padding(12)
            }
            .background(Th.panel)
            .navigationTitle("Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 14) {
            AppBadge(size: 64)
            Text("Mobile Studio").font(.title2.bold()).foregroundStyle(Th.text)
            Text("v2.0").font(.subheadline).foregroundStyle(Th.dim)
            Text("An iOS port of the Mobile Studio Android app. Scripting runs on the open-source Luau VM.")
                .font(.callout).foregroundStyle(Th.text).multilineTextAlignment(.center)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(Th.accent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Th.panel)
        .presentationDetents([.medium])
    }
}
