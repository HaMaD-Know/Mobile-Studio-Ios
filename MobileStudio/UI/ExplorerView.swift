import SwiftUI
import StudioCore

/// Instance tree (port of ui/ExplorerPanel.kt).
struct ExplorerView: View {
    @ObservedObject var store: StudioStore
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
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter workspace", text: $filter).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .padding(8)
            .background(Color(.secondarySystemBackground))

            List(rows()) { row in
                rowView(row)
                    .listRowInsets(EdgeInsets(top: 0, leading: 6 + CGFloat(row.depth) * 14, bottom: 0, trailing: 6))
                    .listRowBackground(store.session.isSelected(row.inst) ? Color.accentColor.opacity(0.25) : Color.clear)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 30)
        }
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

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let i = row.inst
        let id = ObjectIdentifier(i)
        HStack(spacing: 4) {
            if i.children.isEmpty {
                Color.clear.frame(width: 16)
            } else {
                Image(systemName: expanded.contains(id) ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.bold))
                    .frame(width: 16, height: 26)
                    .contentShape(Rectangle())
                    .onTapGesture { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }
            }
            ClassIcon(className: i.className).frame(width: 18)
            Text(i.name).lineLimit(1).font(.callout)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.session.select([i]) }
        .contextMenu {
            Button("Insert Object…", systemImage: "plus") { insertInto = i }
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
            .font(.system(size: 13))
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
        if ClassDb.isA(c, "BasePart") { return .gray }
        if ClassDb.isA(c, "LuaSourceContainer") { return .blue }
        if ClassDb.isA(c, "Light") { return .yellow }
        if c == "Workspace" { return .teal }
        if c == "Model" { return .orange }
        if c == "Folder" { return .brown }
        return .secondary
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
