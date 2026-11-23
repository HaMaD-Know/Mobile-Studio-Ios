import Foundation

/// Undo history (port of core/UndoManager.kt).
public final class UndoManager {
    public enum Op {
        case prop(inst: Instance, name: String, old: PropValue?, new: PropValue)
        case parent(inst: Instance, oldParent: Instance?, oldIndex: Int, newParent: Instance?)
    }
    struct Step { let label: String; let ops: [Op] }

    private var undoStack: [Step] = []
    private var redoStack: [Step] = []
    private var batch: [Op]?
    private var batchLabel = ""
    private var batchDepth = 0
    public var suspended = false
    /// Called after any change to history (to mark the document dirty / refresh UI).
    var onChange: () -> Void = {}
    /// Called after undo/redo re-applies ops.
    var onApplied: () -> Void = {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }

    public func begin(_ label: String) {
        if batchDepth == 0 { batch = []; batchLabel = label }
        batchDepth += 1
    }
    public func commit() {
        guard batchDepth > 0 else { return }
        batchDepth -= 1
        if batchDepth == 0, let b = batch {
            batch = nil
            if !b.isEmpty { push(Step(label: batchLabel, ops: b)) }
        }
    }
    public func record(_ op: Op) {
        if suspended { return }
        if batch != nil { batch!.append(op) } else { push(Step(label: "Edit", ops: [op])) }
    }
    private func push(_ s: Step) {
        undoStack.append(s)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        onChange()
    }
    public func clear() { undoStack.removeAll(); redoStack.removeAll(); batch = nil; batchDepth = 0 }

    @discardableResult public func undo() -> String? {
        guard let s = undoStack.popLast() else { return nil }
        apply(s, reverse: true)
        redoStack.append(s)
        return s.label
    }
    @discardableResult public func redo() -> String? {
        guard let s = redoStack.popLast() else { return nil }
        apply(s, reverse: false)
        undoStack.append(s)
        return s.label
    }

    private func apply(_ s: Step, reverse: Bool) {
        suspended = true
        defer { suspended = false }
        for op in (reverse ? s.ops.reversed() : s.ops) {
            switch op {
            case let .prop(inst, name, old, new):
                if reverse {
                    if let old { inst.set(name, old) } else {
                        inst.props[name] = nil
                        inst.version += 1
                        Instance.changeCount += 1
                        inst.root()?.firePropChanged(inst, name)
                    }
                } else {
                    inst.set(name, new)
                }
            case let .parent(inst, oldParent, oldIndex, newParent):
                if reverse {
                    inst.destroyed = false
                    try? inst.setParent(oldParent, index: oldIndex)
                } else {
                    try? inst.setParent(newParent)
                }
            }
        }
        onChange()
        onApplied()
    }
}

/// The editable document: model, selection, history and the editing commands that the
/// Android app kept in core/Studio.kt. UI-independent so it can be unit tested.
public final class EditSession {
    public private(set) var model: DataModel
    public private(set) var selection: [Instance] = []
    public let undo = UndoManager()
    public private(set) var dirty = false
    private var clipboard: [Instance] = []

    /// Fired after selection changes.
    public var onSelectionChanged: () -> Void = {}
    /// Fired when the dirty flag flips.
    public var onDirtyChanged: () -> Void = {}

    public init(model: DataModel) {
        self.model = model
        undo.onChange = { [weak self] in self?.markDirty() }
        undo.onApplied = { [weak self] in self?.pruneSelection() }
    }

    public func replaceModel(_ dm: DataModel) {
        model = dm
        selection = []
        clipboard = []
        undo.clear()
        dirty = false
        Instance.changeCount += 1
        onSelectionChanged()
        onDirtyChanged()
    }

    public func markDirty() {
        if !dirty { dirty = true; onDirtyChanged() }
    }
    public func markSaved() {
        if dirty { dirty = false; onDirtyChanged() }
    }

    // MARK: selection

    public func select(_ list: [Instance]) {
        var seen = Set<ObjectIdentifier>()
        selection = list.filter { seen.insert(ObjectIdentifier($0)).inserted }
        onSelectionChanged()
    }
    public func toggleSelect(_ i: Instance) {
        if selection.contains(where: { $0 === i }) { selection.removeAll { $0 === i } } else { selection.append(i) }
        onSelectionChanged()
    }
    public func isSelected(_ i: Instance) -> Bool { selection.contains { $0 === i } }
    public func pruneSelection() {
        selection.removeAll { $0.root() !== model }
        onSelectionChanged()
    }

    /// Parts the selection refers to, expanding Models/Folders into their descendant parts.
    public func selectedParts() -> [Instance] {
        var out: [Instance] = []
        var seen = Set<ObjectIdentifier>()
        for s in selection {
            if s.isA("BasePart"), seen.insert(ObjectIdentifier(s)).inserted { out.append(s) }
            if !s.isService && (s.isA("Model") || s.className == "Folder") {
                for d in s.descendants() where d.isA("BasePart") && seen.insert(ObjectIdentifier(d)).inserted { out.append(d) }
            }
        }
        return out
    }

    // MARK: primitive edits (recorded for undo)

    public func setProp(_ inst: Instance, _ name: String, _ value: PropValue) {
        let had = inst.props.contains(name)
        let old = inst.props[name]
        if had && old == value { return }
        undo.begin("Edit \(name)")
        defer { undo.commit() }
        inst.set(name, value)
        undo.record(.prop(inst: inst, name: name, old: old, new: value))

        func sync(_ partner: String, _ pv: PropValue, typeHint: Int? = nil) {
            let pHad = inst.props.contains(partner)
            let pOld = inst.props[partner]
            if pHad && pOld == pv { return }
            if let t = typeHint, inst.propTypes[partner] == nil { inst.propTypes[partner] = t }
            inst.set(partner, pv)
            undo.record(.prop(inst: inst, name: partner, old: pOld, new: pv))
        }

        if inst.className == "Lighting" {
            if name == "ClockTime", let c = value.asFloat {
                var h = c.truncatingRemainder(dividingBy: 24)
                if h < 0 { h += 24 }
                var total = Int((h * 3600).rounded())
                total = ((total % 86400) + 86400) % 86400
                let hh = total / 3600, mm = (total / 60) % 60, ss = total % 60
                sync("TimeOfDay", .string(String(format: "%02d:%02d:%02d", hh, mm, ss)))
            } else if name == "TimeOfDay", let s = value.asString {
                let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
                if parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) {
                    let sec = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
                    let wrappedH = ((h % 24) + 24) % 24
                    let clampedM = Swift.max(0, Swift.min(59, m))
                    let clampedS = Swift.max(0, Swift.min(59, sec))
                    let hours = Float(wrappedH) + Float(clampedM) / 60 + Float(clampedS) / 3600
                    sync("ClockTime", .float(hours))
                }
            }
        } else if inst.isA("BasePart") {
            if name == "BrickColor", case .brickColor(let bc) = value {
                let c = bc.color
                sync("Color3uint8", .color3(c), typeHint: PropType.COLOR3U8)
                if inst.props.contains("Color") { sync("Color", .color3(c), typeHint: PropType.COLOR3) }
            } else if (name == "Color3uint8" || name == "Color"), case .color3(let c) = value {
                let bc = BrickColorV(Int32(BrickColors.closest(c)))
                sync("BrickColor", .brickColor(bc), typeHint: PropType.BRICKCOLOR)
                if name == "Color" {
                    sync("Color3uint8", .color3(c), typeHint: PropType.COLOR3U8)
                } else if inst.props.contains("Color") {
                    sync("Color", .color3(c), typeHint: PropType.COLOR3)
                }
            }
        }
    }

    /// Record a change that was already applied live (e.g. during a drag).
    public func recordProp(_ inst: Instance, _ name: String, old: PropValue?, new: PropValue) {
        undo.record(.prop(inst: inst, name: name, old: old, new: new))
    }

    public func reparent(_ inst: Instance, _ newParent: Instance?) throws {
        let parent = inst.parent
        let idx = parent.map { inst.index(in: $0) } ?? -1
        try inst.setParent(newParent)
        undo.record(.parent(inst: inst, oldParent: parent, oldIndex: idx, newParent: newParent))
    }

    // MARK: commands

    public func deletable(_ i: Instance) -> Bool {
        !(i.isService || i.parent == nil || i === model.workspace.get("CurrentCamera")?.asInstance)
    }

    @discardableResult
    public func insertObject(_ cls: String, into parent: Instance? = nil, at position: Vector3? = nil) -> Instance {
        var target = parent ?? selection.first ?? model.workspace
        let i = InstanceFactory.create(cls)
        if cls == "SpawnLocation" { PlaceFactory.spawnDecal(i) }
        if i.isA("BasePart") {
            if let p = position { i.set("CFrame", .cframe(.at(p)), notify: false) }
            // Parts go into containers, never inside other parts.
            if !(target.isA("Model") || target.isA("WorldRoot") || target.className == "Folder") { target = model.workspace }
        }
        undo.begin("Insert \(cls)")
        try? reparent(i, target)
        undo.commit()
        select([i])
        return i
    }

    /// Insert a part shape from the toolbar: 0 ball, 1 block, 2 cylinder, 3 wedge, 4 corner wedge.
    @discardableResult
    public func insertPart(shape: Int, at position: Vector3) -> Instance {
        let cls = shape == 3 ? "WedgePart" : (shape == 4 ? "CornerWedgePart" : "Part")
        let p = InstanceFactory.create(cls)
        if shape == 0 || shape == 2 {
            p.set("shape", .enumValue(EnumValue(UInt32(shape))), notify: false)
            p.set("size", .vector3(Vector3(2, 2, 2)), notify: false)
        }
        p.set("Anchored", .bool(true), notify: false)
        let size = PartData.size(p)
        p.set("CFrame", .cframe(.at(position + Vector3(0, size.y / 2, 0))), notify: false)
        undo.begin("Insert \(cls)")
        try? reparent(p, model.workspace)
        undo.commit()
        select([p])
        return p
    }

    public func deleteSelection() {
        undo.begin("Delete")
        for i in selection where deletable(i) { try? reparent(i, nil) }
        undo.commit()
        select([])
    }

    public func duplicateSelection() {
        var created: [Instance] = []
        undo.begin("Duplicate")
        for i in selection where deletable(i) {
            let c = i.cloneTree()
            try? reparent(c, i.parent)
            created.append(c)
        }
        undo.commit()
        if !created.isEmpty { select(created) }
    }

    public var hasClipboard: Bool { !clipboard.isEmpty }
    public func copySelection() { clipboard = selection.filter(deletable).map { $0.cloneTree() } }
    public func cutSelection() { copySelection(); deleteSelection() }
    public func paste(into: Instance? = nil) {
        guard !clipboard.isEmpty else { return }
        var created: [Instance] = []
        undo.begin("Paste")
        for c in clipboard {
            let n = c.cloneTree()
            try? reparent(n, into ?? model.workspace)
            created.append(n)
        }
        undo.commit()
        select(created)
    }

    public func groupSelection() {
        let list = selection.filter(deletable)
        guard let parent = list.first?.parent else { return }
        undo.begin("Group")
        let m = InstanceFactory.create("Model")
        try? reparent(m, parent)
        for i in list { try? reparent(i, m) }
        undo.commit()
        select([m])
    }

    public func ungroupSelection() {
        let list = selection.filter { ($0.className == "Model" || $0.className == "Folder") && deletable($0) }
        guard !list.isEmpty else { return }
        undo.begin("Ungroup")
        var freed: [Instance] = []
        for g in list {
            let parent = g.parent
            for c in g.children { try? reparent(c, parent); freed.append(c) }
            try? reparent(g, nil)
        }
        undo.commit()
        select(freed)
    }

    /// Move a dragged instance in the Explorer.
    public func move(_ inst: Instance, to newParent: Instance) {
        guard deletable(inst), newParent !== inst, !newParent.isDescendant(of: inst) else { return }
        undo.begin("Move")
        try? reparent(inst, newParent)
        undo.commit()
    }

    // MARK: serialization

    public func serializePlace() -> Data { RbxBinaryWriter.write(model.children, meta: model.meta) }
    public func serializeSelection() -> Data { RbxBinaryWriter.write(selection.filter(deletable), meta: OrderedDict()) }

    private func defaultParent(for root: Instance) -> Instance {
        let cls = root.className
        if cls == "Sky" || cls == "Atmosphere" || cls == "Clouds" || ClassDb.isA(cls, "PostEffect") {
            return model.getService("Lighting")
        }
        if cls == "ScreenGui" {
            return model.getService("StarterGui")
        }
        if cls == "MaterialVariant" {
            return model.getService("MaterialService")
        }
        return model.workspace
    }

    /// Insert a model file (.rbxm/.rbxmx) under `parent` (or smart service target).
    public func insertDocument(_ doc: RbxDocument, into parent: Instance? = nil) {
        undo.begin("Insert model")
        for r in doc.roots { try? reparent(r, parent ?? defaultParent(for: r)) }
        undo.commit()
        select(doc.roots)
    }
}
