import SwiftUI
import StudioCore

/// Instance tree (port of ui/ExplorerPanel.kt).
struct ExplorerView: View {
    @ObservedObject var store: StudioStore
    var onClose: (() -> Void)? = nil
    var onInsert: (() -> Void)? = nil
    @State private var expanded: Set<ObjectIdentifier> = []
    @State private var renaming: Instance?
    @State private var renameText = ""
    @State private var insertInto: Instance?
    @State private var filter = ""

    private struct Row: Identifiable {
        let inst: Instance
        let depth: Int
        var id: ObjectIdentifier { ObjectIdentifier(inst) }
    }

    private func rows() -> [Row] {
        _ = store.treeVersion
        var out: [Row] = []
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if !f.isEmpty {
            for d in store.model.descendants() where d.name.lowercased().contains(f) || d.className.lowercased().contains(f) {
                out.append(Row(inst: d, depth: 0))
            }
            return out
        }
        func walk(_ i: Instance, _ depth: Int) {
            for c in sortedChildren(i) {
                out.append(Row(inst: c, depth: depth))
                if expanded.contains(ObjectIdentifier(c)) { walk(c, depth + 1) }
            }
        }
        walk(store.model, 0)
        return out
    }

    private func sortedChildren(_ i: Instance) -> [Instance] {
        guard i is DataModel else { return i.children }
        // Services in Studio's order first, the rest after.
        let order = ClassDb.serviceNames
        return i.children.sorted { a, b in
            let ia = order.firstIndex(of: a.className) ?? 999, ib = order.firstIndex(of: b.className) ?? 999
            return ia < ib
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(icon: "list.bullet.indent", tint: Th.warn, title: "Explorer", onClose: onClose) {
                PanelIconButton(icon: "checkmark.square", tint: Th.info) { selectChildren() }
                PanelIconButton(icon: "plus.square", tint: Th.play) { onInsert?() }
                PanelIconButton(icon: "minus.square") { expanded.removeAll() }
            }
            TextField("", text: $filter, prompt: Text("Filter workspace (name or class)").foregroundStyle(Th.dim))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .studioField()
                .padding(6)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows()) { row in rowView(row) }
                }
            }
        }
        .background(Th.panel)
        .onChange(of: store.selection) { _, sel in
            // Reveal newly selected instances.
            for s in sel {
                var p = s.parent
                while let cur = p { expanded.insert(ObjectIdentifier(cur)); p = cur.parent }
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("OK") { if let r = renaming { store.setProp(r, "Name", .string(renameText)) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .sheet(isPresented: Binding(get: { insertInto != nil }, set: { if !$0 { insertInto = nil } })) {
            InsertObjectView { cls in
                if let parent = insertInto { _ = store.session.insertObject(cls, into: parent) }
                insertInto = nil
            }
        }
    }

    private func selectChildren() {
        guard let first = store.selection.first, !first.children.isEmpty else { return }
        expanded.insert(ObjectIdentifier(first))
        store.session.select(first.children)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let i = row.inst
        let id = ObjectIdentifier(i)
        let selected = store.session.isSelected(i)
        HStack(spacing: 6) {
            if i.children.isEmpty {
                Color.clear.frame(width: 22)
            } else {
                Image(systemName: expanded.contains(id) ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Th.selectText : Th.dim)
                    .frame(width: 22, height: 30)
                    .contentShape(Rectangle())
                    .onTapGesture { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }
            }
            ClassIcon(className: i.className).frame(width: 20)
            Text(i.name).lineLimit(1).font(.system(size: 15))
                .foregroundStyle(selected ? Th.selectText : Th.text)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6 + CGFloat(row.depth) * 18)
        .frame(height: 30)
        .background(selected ? Th.select : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if i.isA("LuaSourceContainer") { store.openScript(i) } else { store.session.select([i]); store.focusSelection() }
        }
        .onTapGesture {
            if store.multiSelect { store.session.toggleSelect(i) } else { store.session.select([i]) }
        }
        .contextMenu {
            Button("Insert Object…", systemImage: "plus") { insertInto = i }
            if i.isA("LuaSourceContainer") {
                Button("Open Script", systemImage: "doc.text") { store.openScript(i) }
            }
            Button("Rename", systemImage: "pencil") { renameText = i.name; renaming = i }
            if store.session.deletable(i) {
                Button("Duplicate", systemImage: "plus.square.on.square") { store.session.select([i]); store.session.duplicateSelection() }
                Button("Copy", systemImage: "doc.on.doc") { store.session.select([i]); store.session.copySelection() }
                Button("Cut", systemImage: "scissors") { store.session.select([i]); store.session.cutSelection() }
            }
            if store.session.hasClipboard {
                Button("Paste Into", systemImage: "doc.on.clipboard") { store.session.paste(into: i) }
            }
            if store.session.deletable(i) {
                Button("Group", systemImage: "square.stack.3d.up") { store.session.select([i]); store.session.groupSelection() }
                if i.className == "Model" || i.className == "Folder" {
                    Button("Ungroup", systemImage: "square.stack.3d.up.slash") { store.session.select([i]); store.session.ungroupSelection() }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { store.session.select([i]); store.session.deleteSelection() }
            }
            if i.isA("BasePart") || i.isA("Model") {
                Button("Zoom To", systemImage: "scope") { store.session.select([i]); store.focusSelection() }
            }
        }
        .draggable(i.fullName()) {
            Label(i.name, systemImage: "cube")
        }
        .dropDestination(for: String.self) { items, _ in
            guard let path = items.first, let src = store.model.descendants().first(where: { $0.fullName() == path }) else { return false }
            store.session.move(src, to: i)
            return true
        }
    }
}

/// SF Symbol per class (stand-in for the Android app's BuiltinIcons vector set).
struct ClassIcon: View {
    let className: String
    var body: some View {
        Image(systemName: ClassIcon.symbol(className))
            .font(.system(size: 14))
            .foregroundStyle(ClassIcon.tint(className))
    }
    static func symbol(_ c: String) -> String {
        if ClassDb.isA(c, "BasePart") { return c == "SpawnLocation" ? "flag.fill" : "cube.fill" }
        if ClassDb.isA(c, "LuaSourceContainer") { return c == "ModuleScript" ? "doc.text.fill" : "scroll.fill" }
        if ClassDb.isA(c, "GuiObject") || ClassDb.isA(c, "LayerCollector") { return "rectangle.on.rectangle" }
        if ClassDb.isA(c, "Light") { return "lightbulb.fill" }
        if ClassDb.isA(c, "ValueBase") { return "number" }
        if ClassDb.isA(c, "Constraint") || ClassDb.isA(c, "JointInstance") || c == "WeldConstraint" { return "link" }
        switch c {
        case "Workspace": return "globe.americas.fill"
        case "Players", "Player": return "person.2.fill"
        case "Lighting": return "sun.max.fill"
        case "Model", "WorldModel", "Actor": return "shippingbox.fill"
        case "Folder": return "folder.fill"
        case "Camera": return "video.fill"
        case "Sound", "SoundService", "SoundGroup": return "speaker.wave.2.fill"
        case "Humanoid": return "figure.stand"
        case "Attachment", "Bone": return "smallcircle.filled.circle"
        case "Decal", "Texture": return "photo"
        case "Terrain": return "mountain.2.fill"
        case "ReplicatedStorage", "ServerStorage": return "archivebox.fill"
        case "ServerScriptService", "StarterPlayerScripts", "StarterCharacterScripts": return "gearshape.2.fill"
        case "StarterGui": return "rectangle.3.group.fill"
        case "StarterPack", "Tool": return "hammer.fill"
        case "Teams", "Team": return "flag.2.crossed.fill"
        case "TextChatService", "Chat": return "bubble.left.fill"
        default: return "circle.fill"
        }
    }
    static func tint(_ c: String) -> Color {
        if c == "SpawnLocation" { return Color(argb: -11751600) }
        if ClassDb.isA(c, "BasePart") { return Color(argb: -3355444) }
        if c == "ModuleScript" { return Color(argb: -23296) }
        if c == "LocalScript" { return Color(argb: -11751600) }
        if ClassDb.isA(c, "LuaSourceContainer") { return Color(argb: -9652481) }
        if ClassDb.isA(c, "Light") { return Color(argb: -9216) }
        if ClassDb.isA(c, "GuiObject") || ClassDb.isA(c, "LayerCollector") { return Color(argb: -11751600) }
        switch c {
        case "Workspace": return Color(argb: -12417548)
        case "Players", "Player", "Teams", "Team": return Color(argb: -12417548)
        case "Lighting": return Color(argb: -9216)
        case "Model", "Actor": return Color(argb: -3355444)
        case "Folder": return Color(argb: -2056128)
        case "Terrain": return Color(argb: -11751600)
        case "Camera": return Color(argb: -9652481)
        case "ReplicatedStorage", "ReplicatedFirst", "ServerStorage": return Color(argb: -14575885)
        case "ServerScriptService", "StarterPlayerScripts", "StarterCharacterScripts": return Color(argb: -9652481)
        case "MaterialService": return Color(argb: -5592406)
        case "SoundService", "Sound": return Color(argb: -9652481)
        default: return Color(argb: -7434610)
        }
    }
}

/// Searchable list of insertable classes (ClassDb.insertable).
struct InsertObjectView: View {
    var onPick: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(ClassDb.insertable.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { cls in
                Button { onPick(cls); dismiss() } label: {
                    Label { Text(cls) } icon: { ClassIcon(className: cls) }
                }
                .foregroundStyle(.primary)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Insert Object")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
