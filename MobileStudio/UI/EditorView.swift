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

/// Main editing screen: viewport + Explorer/Properties/Output (port of ui/DockLayout.kt + MainActions.kt).
struct EditorView: View {
    @ObservedObject var store: StudioStore
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var panel: Panel = .explorer
    @State private var showPanel = true
    @State private var multiSelect = false
    @State private var showInsert = false
    @State private var showImporter = false
    @State private var exporting: BinaryFile?
    @State private var exportName = "Place1"
    @State private var exportType: UTType = .rbxl
    @State private var confirmClose = false
    @State private var showFly = true
    @State private var detent: PresentationDetent = .fraction(0.12)
    @State private var sheet: EditorSheet?
    @State private var importingPlugin = false

    enum EditorSheet: String, Identifiable { case settings, toolbox, cloudOpen, cloudPublish; var id: String { rawValue } }

    enum Panel: String, CaseIterable, Identifiable { case explorer = "Explorer", properties = "Properties", output = "Output"; var id: String { rawValue } }

    var body: some View {
        Group {
            if hSize == .regular {
                HStack(spacing: 0) {
                    viewport
                    if showPanel && store.play == nil {
                        Divider()
                        VStack(spacing: 0) {
                            ExplorerView(store: store).frame(maxHeight: .infinity)
                            Divider()
                            PropertiesView(store: store).frame(maxHeight: .infinity)
                        }
                        .frame(width: 340)
                    }
                }
            } else {
                viewport
                    .sheet(isPresented: Binding(get: { showPanel && store.play == nil }, set: { showPanel = $0 || store.play != nil })) {
                        compactPanel
                            .presentationDetents([.fraction(0.12), .medium, .large], selection: $detent)
                            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                            .interactiveDismissDisabled()
                    }
            }
        }
        .toolbar { toolbar }
        .navigationTitle(store.fileName + (store.dirty ? " •" : ""))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showInsert) { InsertObjectView { store.insertObject($0) } }
        .sheet(item: $sheet) { which in
            switch which {
            case .settings: SettingsView(store: store)
            case .toolbox: ToolboxView(store: store)
            case .cloudOpen: CloudPlacesView(store: store, mode: .open)
            case .cloudPublish: CloudPlacesView(store: store, mode: .publish)
            }
        }
        .sheet(item: Binding(get: { store.editingScript.map(ScriptSheetItem.init) }, set: { store.editingScript = $0?.inst })) { item in
            ScriptEditorView(store: store, script: item.inst)
        }
        .fileImporter(isPresented: $importingPlugin, allowedContentTypes: [.item]) { r in
            if case .success(let url) = r { store.importPlugin(url) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: UTType.robloxFiles) { r in
            if case .success(let url) = r { store.open(url) }
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting, contentType: exportType, defaultFilename: exportName) { r in
            switch r {
            case .success(let url): if exportType == .rbxl { store.didExport(to: url) } else { store.showToast("Exported \(url.lastPathComponent)") }
            case .failure(let e): store.showToast("Export failed: \(e.localizedDescription)")
            }
        }
        .confirmationDialog("Close this place?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { store.hasDocument = false }
        } message: { Text("You have unsaved changes.") }
        .overlay(alignment: .top) {
            if let t = store.toast {
                Text(t).font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule()).padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: store.toast)
    }

    @ViewBuilder private var viewport: some View {
        if let play = store.play {
            ViewportView(store: store, multiSelect: false)
                .ignoresSafeArea()
                .overlay { PlayGuiView(store: store, play: play) }
                .overlay { PlayHUD(store: store, play: play) }
        } else {
            ViewportView(store: store, multiSelect: multiSelect)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .topLeading) { toolPicker.padding(10) }
                .overlay(alignment: .bottomLeading) {
                    if showFly { FlyPad(store: store).padding(.leading, 12).padding(.bottom, hSize == .regular ? 16 : 110) }
                }
        }
    }

    private var toolPicker: some View {
        VStack(spacing: 6) {
            ForEach(StudioStore.Tool.allCases) { t in
                Button { store.tool = t } label: {
                    Image(systemName: t.symbol).frame(width: 40, height: 40)
                        .background(store.tool == t ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(store.tool == t ? .white : .primary)
                }
                .accessibilityLabel(t.rawValue)
            }
            Divider().frame(width: 30)
            Button { multiSelect.toggle() } label: {
                Image(systemName: "plus.rectangle.on.rectangle").frame(width: 40, height: 40)
                    .background(multiSelect ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(multiSelect ? .white : .primary)
            }
            .accessibilityLabel("Multi-select")
        }
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var compactPanel: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $panel) { ForEach(Panel.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).padding(10)
            switch panel {
            case .explorer: ExplorerView(store: store)
            case .properties: PropertiesView(store: store)
            case .output: OutputView(store: store)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Menu {
                Button("Save", systemImage: "square.and.arrow.down") { save() }
                Button("Save As…", systemImage: "square.and.arrow.down.on.square") { saveAs() }
                Button("Export Selection as Model…", systemImage: "shippingbox") { exportSelection() }
                    .disabled(store.selection.isEmpty)
                Divider()
                Button("Publish to Roblox…", systemImage: "icloud.and.arrow.up") { publish() }
                Button("Open from Roblox…", systemImage: "icloud.and.arrow.down") { sheet = .cloudOpen }
                Divider()
                Button("Open…", systemImage: "folder") { showImporter = true }
                Menu("New Place", systemImage: "doc.badge.plus") {
                    ForEach(PlaceFactory.Template.allCases) { t in Button(t.title) { store.newPlace(t) } }
                }
                Divider()
                Button("Close Place", systemImage: "xmark") { if store.dirty { confirmClose = true } else { store.hasDocument = false } }
            } label: { Image(systemName: "doc") }
            Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!store.session.undo.canUndo)
            Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!store.session.undo.canRedo)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { store.play == nil ? store.startPlay() : store.stopPlay() } label: {
                Image(systemName: store.play == nil ? "play.fill" : "stop.fill").foregroundStyle(store.play == nil ? .green : .red)
            }
            .accessibilityLabel(store.play == nil ? "Play" : "Stop")
            Menu {
                Button("Block", systemImage: "cube") { store.insertPart(shape: 1) }
                Button("Sphere", systemImage: "circle") { store.insertPart(shape: 0) }
                Button("Cylinder", systemImage: "cylinder") { store.insertPart(shape: 2) }
                Button("Wedge", systemImage: "triangle") { store.insertPart(shape: 3) }
                Button("Corner Wedge", systemImage: "pyramid") { store.insertPart(shape: 4) }
                Divider()
                Button("Insert Object…", systemImage: "plus.square.dashed") { showInsert = true }
                Button("Toolbox…", systemImage: "square.grid.2x2") { sheet = .toolbox }
                Button("Insert Model File…", systemImage: "square.and.arrow.down") { showImporter = true }
            } label: { Image(systemName: "plus.circle") }
            Menu {
                Button("Duplicate", systemImage: "plus.square.on.square") { store.session.duplicateSelection() }
                Button("Copy", systemImage: "doc.on.doc") { store.session.copySelection() }
                Button("Cut", systemImage: "scissors") { store.session.cutSelection() }
                Button("Paste", systemImage: "doc.on.clipboard") { store.session.paste() }.disabled(!store.session.hasClipboard)
                Divider()
                Button("Group", systemImage: "square.stack.3d.up") { store.session.groupSelection() }
                Button("Ungroup", systemImage: "square.stack.3d.up.slash") { store.session.ungroupSelection() }
                Button("Focus", systemImage: "scope") { store.focusSelection() }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { store.session.deleteSelection() }
            } label: { Image(systemName: "ellipsis.circle") }
            Menu {
                Toggle("Snap to Grid", isOn: $store.snapEnabled)
                Picker("Move Snap", selection: $store.moveSnap) {
                    ForEach([0.1, 0.25, 0.5, 1, 2, 4] as [Float], id: \.self) { Text("\(fmtStud($0)) studs").tag($0) }
                }
                Picker("Rotate Snap", selection: $store.rotSnapDegrees) {
                    ForEach([1, 5, 15, 45, 90] as [Float], id: \.self) { Text("\(Int($0))°").tag($0) }
                }
                Toggle("Select Inside Models", isOn: $store.selectInsideModels)
                Toggle("Fly Controls", isOn: $showFly)
            } label: { Image(systemName: "slider.horizontal.3") }
            Menu {
                ForEach(store.pluginButtons) { b in
                    Button { store.pluginHost?.click(b.inst) } label: {
                        Label(b.text, systemImage: b.active ? "checkmark.circle.fill" : "puzzlepiece.extension")
                    }
                }
                if !store.pluginButtons.isEmpty { Divider() }
                Button("Install Plugin…", systemImage: "square.and.arrow.down") { importingPlugin = true }
                Button("Settings", systemImage: "gearshape") { sheet = .settings }
            } label: { Image(systemName: "puzzlepiece.extension") }
            if hSize == .regular {
                Button { withAnimation { showPanel.toggle() } } label: { Image(systemName: "sidebar.trailing") }
            }
        }
    }

    private func fmtStud(_ f: Float) -> String { f == f.rounded() ? String(Int(f)) : String(f) }

    private func save() {
        if !store.saveInPlace() { saveAs() }
    }
    private func saveAs() {
        exportType = .rbxl
        exportName = store.fileName
        exporting = BinaryFile(data: store.placeData())
    }
    private func publish() {
        guard let cloud = store.cloudPlace else { sheet = .cloudPublish; return }
        Task {
            do {
                let v = try await RobloxWeb.publish(universe: cloud.0, place: cloud.1, bytes: store.placeData(), publish: true)
                store.showToast("Published (" + v + ")")
            } catch { store.showToast(error.localizedDescription) }
        }
    }

    private func exportSelection() {
        exportType = .rbxm
        exportName = store.selection.first?.name ?? "Model"
        exporting = BinaryFile(data: store.session.serializeSelection())
    }
}

struct ScriptSheetItem: Identifiable {
    let inst: Instance
    var id: ObjectIdentifier { ObjectIdentifier(inst) }
}

/// Output log plus the command bar (Luau in the edit model, or in the Play session while playing).
struct OutputView: View {
    @ObservedObject var store: StudioStore
    @State private var command = ""
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(Array(store.output.enumerated()), id: \.offset) { item in
                    Text(item.element).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(item.element.hasPrefix("⛔︎") ? Color.red : (item.element.hasPrefix("⚠︎") ? Color.orange : Color.primary))
                        .id(item.offset)
                }
                .listStyle(.plain)
                .onChange(of: store.output.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
            HStack {
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                TextField("Run a command", text: $command)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit {
                        guard !command.isEmpty else { return }
                        store.runCommand(command)
                        command = ""
                    }
            }
            .padding(8)
            .background(Color(.secondarySystemBackground))
        }
    }
}
