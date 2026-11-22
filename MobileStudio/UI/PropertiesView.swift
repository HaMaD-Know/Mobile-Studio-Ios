import SwiftUI
import StudioCore

/// Property inspector (port of ui/PropertiesPanel.kt): properties grouped into collapsible
/// categories, name on the left and value on the right. Edits apply to every selected instance
/// of the same class and are recorded for undo.
struct PropertiesView: View {
    @ObservedObject var store: StudioStore
    var onClose: (() -> Void)? = nil
    @State private var collapsed: Set<String> = []

    var body: some View {
        let _ = store.propsVersion
        let inst = store.selection.first
        VStack(spacing: 0) {
            PanelHeader(icon: "list.bullet.rectangle", tint: Th.info, title: "Properties",
                        subtitle: inst.map { subtitle($0) }, onClose: onClose)
            if let inst {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groups(inst), id: \.0) { group in
                            categoryHeader(group.0)
                            if !collapsed.contains(group.0) {
                                ForEach(group.1, id: \.self) { name in
                                    PropertyRow(store: store, inst: inst, name: name)
                                }
                            }
                        }
                        if inst.isA("LuaSourceContainer") {
                            Button { store.openScript(inst) } label: {
                                Label("Open Script", systemImage: "doc.text").font(.system(size: 14))
                                    .frame(maxWidth: .infinity).frame(height: 34)
                                    .background(Th.accent, in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                        }
                    }
                }
            } else {
                Spacer()
            }
        }
        .background(Th.panel)
    }

    private func subtitle(_ i: Instance) -> String {
        store.selection.count > 1 ? "\(store.selection.count) selected" : "\(i.className) \"\(i.name)\""
    }

    private func categoryHeader(_ name: String) -> some View {
        Button {
            if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: collapsed.contains(name) ? "arrowtriangle.right.fill" : "arrowtriangle.down.fill")
                    .font(.system(size: 11)).foregroundStyle(Th.text)
                Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Th.text)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(Th.header)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// (category, property names) in the Android panel's category order.
    private func groups(_ i: Instance) -> [(String, [String])] {
        let hidden: Set<String> = ["Source", "Tags", "AttributesSerialize", "ScriptGuid", "HistoryId", "SourceAssetId", "UniqueId"]
        var byCat: [String: [String]] = ["Data": ["ClassName"]]
        for k in i.props.keys {
            guard !hidden.contains(k), let v = i.props[k], !PropType.hidden(i.propTypes[k] ?? PropType.infer(v), v) else { continue }
            let cat = PropCategories.map[PropertyRow.displayName(k)] ?? PropCategories.map[k] ?? (k == "Name" ? "Data" : "Other")
            byCat[cat, default: []].append(k)
        }
        if i.props["CFrame"] != nil { byCat["Transform", default: []].append("#Orientation") }
        if !i.attributes.isEmpty { byCat["Attributes"] = i.attributes.keys.map { "@" + $0 } }
        var out: [(String, [String])] = []
        for c in PropCategories.order + ["Attributes"] {
            guard var names = byCat.removeValue(forKey: c) else { continue }
            names.sort(by: PropertiesView.order)
            out.append((c, names))
        }
        for (c, names) in byCat.sorted(by: { $0.key < $1.key }) { out.append((c, names.sorted())) }
        return out
    }

    private static func order(_ a: String, _ b: String) -> Bool {
        if a == "ClassName" { return true }
        if b == "ClassName" { return false }
        if a == "Name" { return true }
        if b == "Name" { return false }
        return PropertyRow.displayName(a).localizedCaseInsensitiveCompare(PropertyRow.displayName(b)) == .orderedAscending
    }
}

/// One property row: name | value editor.
struct PropertyRow: View {
    @ObservedObject var store: StudioStore
    let inst: Instance
    let name: String

    var body: some View {
        HStack(spacing: 0) {
            Text(Self.displayName(name))
                .font(.system(size: 14)).foregroundStyle(Th.dim).lineLimit(1)
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            Th.border.frame(width: 1)
            editor
                .font(.system(size: 14)).foregroundStyle(Th.text)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 32)
        .background(Th.panel)
        .overlay(alignment: .bottom) { Th.border.opacity(0.6).frame(height: 1) }
    }

    @ViewBuilder private var editor: some View {
        if name == "ClassName" {
            Text(inst.className)
        } else if name == "#Orientation", case .cframe(let cf)? = inst.props["CFrame"] {
            CommitField(text: Self.fmt(Self.degrees(cf))) { s in
                guard let d = Self.parse3(s) else { return }
                let r = CFrame.fromOrientation(d.x * .pi / 180, d.y * .pi / 180, d.z * .pi / 180)
                store.setProp(inst, "CFrame", .cframe(r.withPosition(cf.position)))
            }
        } else if name.hasPrefix("@") {
            Text(inst.attributes[String(name.dropFirst())]?.description ?? "").lineLimit(1)
        } else {
            valueEditor(inst.props[name] ?? .string(""))
        }
    }

    @ViewBuilder private func valueEditor(_ value: PropValue) -> some View {
        switch value {
        case .bool(let b):
            StudioCheckbox(isOn: Binding(get: { b }, set: { set(.bool($0)) }))
        case .string(let s):
            CommitField(text: s) { set(.string($0)) }
        case .int(let n):
            NumberField(value: Double(n)) { set(.int(Int32(clamping: Int($0)))) }
        case .int64(let n):
            NumberField(value: Double(n)) { set(.int64(Int64($0))) }
        case .float(let f):
            NumberField(value: Double(f)) { set(.float(Float($0))) }
        case .double(let d):
            NumberField(value: d) { set(.double($0)) }
        case .vector3(let v):
            CommitField(text: Self.fmt(v)) { if let nv = Self.parse3($0) { set(.vector3(nv)) } }
        case .cframe(let cf):
            CommitField(text: Self.fmt(cf.position)) { if let p = Self.parse3($0) { set(.cframe(cf.withPosition(p))) } }
        case .color3(let c):
            ColorRowEditor(color: c) { set(.color3($0)) }
        case .brickColor(let bc):
            brickColorMenu(bc)
        case .enumValue(let e):
            enumEditor(e)
        case .ref(let r):
            Text(r?.name ?? "").lineLimit(1)
        default:
            Text(value.description).lineLimit(2)
        }
    }

    private func brickColorMenu(_ bc: BrickColorV) -> some View {
        Menu {
            ForEach(BrickColors.all, id: \.self) { n in
                Button(BrickColors.name(n)) { set(.brickColor(BrickColorV(Int32(n)))) }
            }
        } label: {
            HStack(spacing: 8) {
                swatch(bc.color)
                Text(BrickColors.name(Int(bc.number))).foregroundStyle(Th.text).lineLimit(1)
            }
        }
    }

    @ViewBuilder private func enumEditor(_ e: EnumValue) -> some View {
        if let t = Enums.typeForProp(name), !Enums.items(t).isEmpty {
            let items = Enums.items(t)
            Menu {
                ForEach(items, id: \.1) { item in
                    Button(item.0) { set(.enumValue(EnumValue(UInt32(item.1)))) }
                }
            } label: {
                HStack {
                    Text(items.first { $0.1 == Int(e.value) }?.0 ?? String(e.value)).foregroundStyle(Th.text)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(Th.dim)
                }
            }
        } else {
            NumberField(value: Double(e.value)) { set(.enumValue(EnumValue(UInt32(max(0, $0))))) }
        }
    }

    private func swatch(_ c: Color3) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b)))
            .frame(width: 18, height: 18)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Th.dim, lineWidth: 1))
    }

    static func displayName(_ name: String) -> String {
        switch name {
        case "size": return "Size"
        case "shape": return "Shape"
        case "Color3uint8": return "Color"
        case "formFactorRaw": return "FormFactor"
        case "Health_XML": return "Health"
        case "CFrame": return "Position"
        case "#Orientation": return "Orientation"
        default: return name.hasPrefix("@") ? String(name.dropFirst()) : name
        }
    }

    static func degrees(_ cf: CFrame) -> Vector3 {
        let o = cf.toOrientation
        func r(_ f: Float) -> Float { ((f * 180 / .pi) * 1000).rounded() / 1000 }
        return Vector3(r(o.x), r(o.y), r(o.z))
    }

    static func fmt(_ v: Vector3) -> String { [v.x, v.y, v.z].map { num(Double($0)) }.joined(separator: ", ") }

    static func num(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e12 { return String(Int64(v)) }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func parse3(_ s: String) -> Vector3? {
        let parts = s.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Float($0) }
        return parts.count == 3 ? Vector3(parts[0], parts[1], parts[2]) : nil
    }

    private func set(_ v: PropValue) { store.setProp(inst, name, v) }
}

/// Swatch + "r, g, b" (0-255) editor; tapping the swatch opens the multi-mode Studio colour picker.
struct ColorRowEditor: View {
    let color: Color3
    let commit: (Color3) -> Void
    @State private var showPicker = false

    var body: some View {
        HStack(spacing: 8) {
            Button { showPicker = true } label: {
                RoundedRectangle(cornerRadius: 3)
                    .fill(swiftColor)
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Th.dim, lineWidth: 1))
            }
            .buttonStyle(.plain)
            CommitField(text: rgbText) { s in
                let p = s.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Float($0) }
                if p.count == 3 { commit(Color3(p[0] / 255, p[1] / 255, p[2] / 255)) }
            }
        }
        .sheet(isPresented: $showPicker) {
            StudioColorPickerSheet(title: "Color", initial: color) { commit($0) }
        }
    }

    private var swiftColor: Color { Color(red: Double(color.r), green: Double(color.g), blue: Double(color.b)) }
    private var rgbText: String { [color.r, color.g, color.b].map { String(Int(($0 * 255).rounded())) }.joined(separator: ", ") }
}

/// Text field that commits on return / focus loss.
struct CommitField: View {
    let text: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .multilineTextAlignment(.leading)
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { _, n in if !focused { draft = n } }
            .onChange(of: focused) { _, f in if !f && draft != text { commit(draft) } }
            .onSubmit { if draft != text { commit(draft) } }
    }
}

/// Numeric field that commits parsed values on return / focus loss.
struct NumberField: View {
    let value: Double
    let commit: (Double) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    private static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e12 { return String(Int64(v)) }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    var body: some View {
        TextField("0", text: $draft)
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.leading)
            .monospacedDigit()
            .frame(minWidth: 50)
            .focused($focused)
            .onAppear { draft = Self.format(value) }
            .onChange(of: value) { _, v in if !focused { draft = Self.format(v) } }
            .onChange(of: focused) { _, f in if !f { apply() } }
            .onSubmit(apply)
    }

    private func apply() {
        let s = draft.trimmingCharacters(in: .whitespaces)
        if let d = Double(s.replacingOccurrences(of: ",", with: ".")), d.isFinite, d != value { commit(d) } else { draft = Self.format(value) }
    }
}

struct Vector3Editor: View {
    let value: Vector3
    let commit: (Vector3) -> Void
    var body: some View {
        HStack(spacing: 6) {
            axis("X", value.x, .red) { var v = value; v.x = $0; commit(v) }
            axis("Y", value.y, .green) { var v = value; v.y = $0; commit(v) }
            axis("Z", value.z, .blue) { var v = value; v.z = $0; commit(v) }
        }
    }
    private func axis(_ l: String, _ f: Float, _ c: Color, _ set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 2) {
            Text(l).font(.caption.bold()).foregroundStyle(c)
            NumberField(value: Double(f)) { set(Float($0)) }
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}
