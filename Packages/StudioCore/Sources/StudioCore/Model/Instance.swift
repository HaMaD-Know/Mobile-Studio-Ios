import Foundation

/// Insertion-ordered dictionary (stands in for Kotlin's LinkedHashMap).
public struct OrderedDict<Value>: Sequence {
    public private(set) var keys: [String] = []
    private var storage: [String: Value] = [:]
    public init() {}
    public subscript(key: String) -> Value? {
        get { storage[key] }
        set {
            if let v = newValue {
                if storage.updateValue(v, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }
    public func contains(_ key: String) -> Bool { storage[key] != nil }
    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public var values: [Value] { keys.map { storage[$0]! } }
    public mutating func merge(_ other: OrderedDict<Value>) { for (k, v) in other { self[k] = v } }
    public func makeIterator() -> AnyIterator<(key: String, value: Value)> {
        var i = 0
        return AnyIterator {
            guard i < keys.count else { return nil }
            defer { i += 1 }
            return (keys[i], storage[keys[i]]!)
        }
    }
}

public protocol TreeListener: AnyObject {
    func childAdded(_ parent: Instance, _ child: Instance)
    func childRemoved(_ parent: Instance, _ child: Instance)
    func propChanged(_ inst: Instance, _ name: String)
}

public enum InstanceError: Error, LocalizedError {
    case circularParent(String, String)
    public var errorDescription: String? {
        switch self {
        case .circularParent(let a, let b): return "Attempt to set parent of \(a) to \(b) would result in circular reference"
        }
    }
}

/// Generic, dynamically-typed node of the scene tree (port of model/Instance.kt).
public class Instance: Hashable, CustomStringConvertible {
    /// Bumped on every edit anywhere; the renderer uses it to know when to rebuild.
    public static var changeCount: Int = 0

    public var className: String
    public var props = OrderedDict<PropValue>()
    public var propTypes: [String: Int] = [:]
    public internal(set) weak var parent: Instance?
    public internal(set) var children: [Instance] = []
    public var isService = false
    public var archivable = true
    public var destroyed = false
    /// Referent id the instance had in the file it was loaded from (-1 if created in the app).
    public var loadedRef = -1
    public var attributes = OrderedDict<PropValue>()
    /// Incremented when this instance (or a shape-affecting child) changes.
    public var version = 0
    /// Scratch slot for the renderer's per-instance cache.
    public var renderRec: AnyObject?

    public init(_ className: String) { self.className = className }

    public static func == (a: Instance, b: Instance) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
    public var description: String { name }

    public var name: String {
        get { if case .string(let s)? = props["Name"] { return s }; return className }
        set { set("Name", .string(newValue)) }
    }

    public func get(_ name: String) -> PropValue? { props[name] }

    public func set(_ name: String, _ value: PropValue, notify: Bool = true) {
        if let old = props[name], old == value { return }
        props[name] = value
        version += 1
        if affectsParentShape, let p = parent { p.version += 1 }
        Instance.changeCount += 1
        if propTypes[name] == nil { propTypes[name] = PropType.infer(value) }
        if notify, let root = root() { root.firePropChanged(self, name) }
    }

    private var affectsParentShape: Bool {
        switch className {
        case "BlockMesh", "FileMesh", "SpecialMesh", "SurfaceAppearance", "CylinderMesh", "BevelMesh": return true
        default: return (parent?.isA("PartOperation") ?? false) && isA("BasePart")
        }
    }

    public func root() -> DataModel? {
        var p: Instance? = self
        while let cur = p { if let dm = cur as? DataModel { return dm }; p = cur.parent }
        return nil
    }

    public func isDescendant(of other: Instance) -> Bool {
        var p = parent
        while let cur = p { if cur === other { return true }; p = cur.parent }
        return false
    }

    public func setParent(_ newParent: Instance?, index: Int = -1) throws {
        if newParent === parent { return }
        if let np = newParent, np === self || np.isDescendant(of: self) {
            throw InstanceError.circularParent(name, np.name)
        }
        let old = parent
        version += 1
        Instance.changeCount += 1
        let shape = affectsParentShape
        if let old {
            if shape { old.version += 1 }
            old.children.removeAll { $0 === self }
            parent = nil
            old.root()?.fireChildRemoved(old, self)
        }
        if let np = newParent {
            if shape { np.version += 1 }
            if index >= 0 && index <= np.children.count { np.children.insert(self, at: index) } else { np.children.append(self) }
            parent = np
            np.root()?.fireChildAdded(np, self)
        }
    }

    /// Attach without notifications or checks (used while loading).
    public func attachRaw(_ p: Instance) {
        parent = p
        p.children.append(self)
    }

    public func destroy() {
        if destroyed { return }
        try? setParent(nil)
        markDestroyed()
    }
    private func markDestroyed() {
        destroyed = true
        for c in children { c.markDestroyed() }
    }

    public func isA(_ cls: String) -> Bool { ClassDb.isA(className, cls) }

    public func findFirstChild(_ n: String, recursive: Bool = false) -> Instance? {
        if let c = children.first(where: { $0.name == n }) { return c }
        if recursive { for c in children { if let f = c.findFirstChild(n, recursive: true) { return f } } }
        return nil
    }
    public func findFirstChildOfClass(_ cls: String) -> Instance? { children.first { $0.className == cls } }
    public func findFirstChildWhichIsA(_ cls: String, recursive: Bool = false) -> Instance? {
        if let c = children.first(where: { $0.isA(cls) }) { return c }
        if recursive { for c in children { if let f = c.findFirstChildWhichIsA(cls, recursive: true) { return f } } }
        return nil
    }

    public func descendants() -> [Instance] {
        var out: [Instance] = []
        func walk(_ i: Instance) { for c in i.children { out.append(c); walk(c) } }
        walk(self)
        return out
    }

    public func fullName() -> String {
        var parts: [String] = []
        var p: Instance? = self
        while let cur = p, !(cur is DataModel) { parts.append(cur.name); p = cur.parent }
        return parts.reversed().joined(separator: ".")
    }

    public func index(in parent: Instance) -> Int { parent.children.firstIndex { $0 === self } ?? -1 }

    public func cloneTree() -> Instance {
        var map: [ObjectIdentifier: Instance] = [:]
        let r = Instance.copyInto(self, &map, Instance(className))
        Instance.remapRefs(map)
        return r
    }

    static func copyInto(_ src: Instance, _ map: inout [ObjectIdentifier: Instance], _ dst: Instance) -> Instance {
        dst.props.merge(src.props)
        for (k, v) in src.propTypes { dst.propTypes[k] = v }
        dst.isService = src.isService
        dst.attributes.merge(src.attributes)
        map[ObjectIdentifier(src)] = dst
        for ch in src.children where ch.archivable {
            let cc = copyInto(ch, &map, Instance(ch.className))
            cc.attachRaw(dst)
        }
        return dst
    }

    /// Point Ref/Content properties of the copies at the copied targets (when the target was copied too).
    static func remapRefs(_ map: [ObjectIdentifier: Instance]) {
        for c in map.values {
            for (k, v) in c.props {
                switch v {
                case .ref(let t?):
                    if let n = map[ObjectIdentifier(t)] { c.props[k] = .ref(n) }
                case .content(var cv):
                    if let t = cv.obj, let n = map[ObjectIdentifier(t)] { cv.obj = n; c.props[k] = .content(cv) }
                default: break
                }
            }
        }
    }
}

/// Root of a place (port of model/DataModel.kt).
public final class DataModel: Instance {
    private var listeners: [WeakListener] = []
    public var meta = OrderedDict<String>()

    private struct WeakListener { weak var l: TreeListener? }

    public init() {
        super.init("DataModel")
        props["Name"] = .string("Game")
    }

    public func addListener(_ l: TreeListener) { listeners.append(WeakListener(l: l)) }
    public func removeListener(_ l: TreeListener) { listeners.removeAll { $0.l == nil || $0.l === l } }

    func fireChildAdded(_ p: Instance, _ c: Instance) { for w in listeners { w.l?.childAdded(p, c) } }
    func fireChildRemoved(_ p: Instance, _ c: Instance) { for w in listeners { w.l?.childRemoved(p, c) } }
    func firePropChanged(_ i: Instance, _ n: String) { for w in listeners { w.l?.propChanged(i, n) } }

    public func findService(_ cls: String) -> Instance? { children.first { $0.className == cls } }
    public func getService(_ cls: String) -> Instance {
        if let s = findService(cls) { return s }
        let s = InstanceFactory.create(cls)
        s.isService = true
        try? s.setParent(self)
        return s
    }
    public var workspace: Instance { getService("Workspace") }

    public func cloneModel() -> DataModel {
        var map: [ObjectIdentifier: Instance] = [:]
        let dm = DataModel()
        dm.meta.merge(meta)
        _ = Instance.copyInto(self, &map, dm)
        Instance.remapRefs(map)
        return dm
    }
}
