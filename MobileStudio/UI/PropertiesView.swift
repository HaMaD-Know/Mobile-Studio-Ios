import SwiftUI
import StudioCore

/// Property inspector (port of ui/PropertiesPanel.kt). Edits apply to every selected instance
/// of the same class and are recorded for undo.
struct PropertiesView: View {
    @ObservedObject var store: StudioStore
    @State private var editingScript: Instance?

    var body: some View {
        let _ = store.propsVersion
        if let inst = store.selection.first {
            List {
                Section {
                    LabeledContent("ClassName", value: inst.className)
                    if store.selection.count > 1 {
                        LabeledContent("Selected", value: "\(store.selection.count) objects")
                    }
                    if inst.isA("LuaSourceContainer") {
                        Button("Edit Script", systemImage: "chevron.left.forwardslash.chevron.right") { editingScript = inst }
                    }
                }
                Section("Properties") {
                    ForEach(propNames(inst), id: \.self) { name in
                        PropertyRow(store: store, inst: inst, name: name)
                    }
                }
                if !inst.attributes.isEmpty {
                    Section("Attributes") {
                        ForEach(inst.attributes.keys, id: \.self) { k in
                            LabeledContent(k, value: inst.attributes[k]?.description ?? "")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 34)
            .sheet(item: Binding(get: { editingScript.map(ScriptBox.init) }, set: { editingScript = $0?.inst })) { box in
                ScriptEditorView(store: store, script: box.inst)
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "cursorarrow.click.2",
                                   description: Text("Tap a part in the viewport or an item in the Explorer."))
        }
    }

    private func propNames(_ i: Instance) -> [String] {
        let hidden: Set<String> = ["Source", "Tags", "AttributesSerialize", "ScriptGuid", "HistoryId", "SourceAssetId", "UniqueId"]
        var names = i.props.keys.filter { k in
            guard !hidden.contains(k), let v = i.props[k] else { return false }
            return !PropType.hidden(i.propTypes[k] ?? PropType.infer(v), v)
        }
        names.sort { a, b in
            if a == "Name" { return true }
            if b == "Name" { return false }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return names
    }

    private struct ScriptBox: Identifiable {
        let inst: Instance
        var id: ObjectIdentifier { ObjectIdentifier(inst) }
    }
}

/// One editable property.
struct PropertyRow: View {
    @ObservedObject var store: StudioStore
    let inst: Instance
    let name: String

    var body: some View {
        let value = inst.props[name] ?? .string("")
        let label = displayName
        switch value {
        case .bool(let b):
            Toggle(label, isOn: Binding(get: { b }, set: { set(.bool($0)) }))
        case .string(let s):
            LabeledContent(label) { CommitField(text: s) { set(.string($0)) } }
        case .int(let n):
            LabeledContent(label) { NumberField(value: Double(n)) { set(.int(Int32(clamping: Int($0)))) } }
        case .int64(let n):
            LabeledContent(label) { NumberField(value: Double(n)) { set(.int64(Int64($0))) } }
        case .float(let f):
            LabeledContent(label) { NumberField(value: Double(f)) { set(.float(Float($0))) } }
        case .double(let d):
            LabeledContent(label) { NumberField(value: d) { set(.double($0)) } }
        case .vector3(let v):
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                Vector3Editor(value: v) { set(.vector3($0)) }
            }
        case .cframe(let cf):
            VStack(alignment: .leading, spacing: 4) {
                Text("\(label) · Position")
                Vector3Editor(value: cf.position) { set(.cframe(cf.withPosition($0))) }
                Text("\(label) · Orientation (°)")
                Vector3Editor(value: orientationDegrees(cf)) { d in
                    let r = CFrame.fromOrientation(d.x * .pi / 180, d.y * .pi / 180, d.z * .pi / 180)
                    set(.cframe(r.withPosition(cf.position)))
                }
            }
        case .color3(let c):
            ColorPicker(label, selection: Binding(
                get: { Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b)) },
                set: { newColor in
                    let ui = UIColor(newColor)
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
                    set(.color3(Color3(Float(r), Float(g), Float(b))))
                }), supportsOpacity: false)
        case .brickColor(let bc):
            Picker(label, selection: Binding(get: { Int(bc.number) }, set: { set(.brickColor(BrickColorV(Int32($0)))) })) {
                ForEach(BrickColors.all + (BrickColors.all.contains(Int(bc.number)) ? [] : [Int(bc.number)]), id: \.self) { n in
                    Text(BrickColors.name(n)).tag(n)
                }
            }
        case .enumValue(let e):
            if let t = Enums.typeForProp(name), !Enums.items(t).isEmpty {
                Picker(label, selection: Binding(get: { Int(e.value) }, set: { set(.enumValue(EnumValue(UInt32($0)))) })) {
                    ForEach(enumItems(t, current: Int(e.value)), id: \.1) { item in Text(item.0).tag(item.1) }
                }
            } else {
                LabeledContent(label) { NumberField(value: Double(e.value)) { set(.enumValue(EnumValue(UInt32(max(0, $0))))) } }
            }
        case .ref(let r):
            LabeledContent(label, value: r?.name ?? "")
        default:
            LabeledContent(label, value: value.description).lineLimit(2)
        }
    }

    private var displayName: String {
        switch name {
        case "size": return "Size"
        case "shape": return "Shape"
        case "Color3uint8": return "Color"
        case "formFactorRaw": return "FormFactor"
        default: return name
        }
    }

    private func enumItems(_ t: String, current: Int) -> [(String, Int)] {
        var items = Enums.items(t)
        if !items.contains(where: { $0.1 == current }) { items.append((String(current), current)) }
        return items
    }

    private func orientationDegrees(_ cf: CFrame) -> Vector3 {
        let o = cf.toOrientation
        func r(_ f: Float) -> Float { ((f * 180 / .pi) * 1000).rounded() / 1000 }
        return Vector3(r(o.x), r(o.y), r(o.z))
    }

    private func set(_ v: PropValue) { store.setProp(inst, name, v) }
}

/// Text field that commits on return / focus loss.
struct CommitField: View {
    let text: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .multilineTextAlignment(.trailing)
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
            .multilineTextAlignment(.trailing)
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
