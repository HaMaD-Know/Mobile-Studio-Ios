import Foundation

// Property data types ported from model/DataTypes.kt and friends.

public struct UDim: Hashable, CustomStringConvertible {
    public var scale: Float, offset: Int32
    public init(_ scale: Float, _ offset: Int32) { self.scale = scale; self.offset = offset }
    public var description: String { "\(fmt(scale)), \(offset)" }
}

public struct UDim2: Hashable, CustomStringConvertible {
    public var x: UDim, y: UDim
    public init(_ xs: Float, _ xo: Int32, _ ys: Float, _ yo: Int32) { x = UDim(xs, xo); y = UDim(ys, yo) }
    public var description: String { "{\(x)}, {\(y)}" }
}

public struct Ray: Hashable, CustomStringConvertible {
    public var origin: Vector3, direction: Vector3
    public init(_ o: Vector3, _ d: Vector3) { origin = o; direction = d }
    public var description: String { "{\(origin)}, {\(direction)}" }
}

/// Bit set of NormalIds (Right, Top, Back, Left, Bottom, Front).
public struct Faces: Hashable, CustomStringConvertible {
    public var bits: UInt8
    public init(_ bits: UInt8) { self.bits = bits }
    static let names = ["Right", "Top", "Back", "Left", "Bottom", "Front"]
    public var description: String { Faces.names.enumerated().filter { bits & (1 << $0.offset) != 0 }.map(\.element).joined(separator: ", ") }
}

public struct Axes: Hashable, CustomStringConvertible {
    public var bits: UInt8
    public init(_ bits: UInt8) { self.bits = bits }
    public var description: String { ["X", "Y", "Z"].enumerated().filter { bits & (1 << $0.offset) != 0 }.map(\.element).joined(separator: ", ") }
}

public struct BrickColorV: Hashable, CustomStringConvertible {
    public var number: Int32
    public init(_ number: Int32) { self.number = number }
    public var color: Color3 { BrickColors.color(Int(number)) }
    public var description: String { BrickColors.name(Int(number)) }
}

public struct EnumValue: Hashable, CustomStringConvertible {
    public var value: UInt32
    public init(_ value: UInt32) { self.value = value }
    public var description: String { String(value) }
}

public struct Vector3int16: Hashable, CustomStringConvertible {
    public var x: Int16, y: Int16, z: Int16
    public init(_ x: Int16, _ y: Int16, _ z: Int16) { self.x = x; self.y = y; self.z = z }
    public var description: String { "\(x), \(y), \(z)" }
}

public struct NumberKey: Hashable { public var time: Float, value: Float, envelope: Float
    public init(_ t: Float, _ v: Float, _ e: Float) { time = t; value = v; envelope = e } }
public struct NumberSequence: Hashable, CustomStringConvertible {
    public var keys: [NumberKey]
    public init(_ keys: [NumberKey]) { self.keys = keys }
    public var description: String { keys.map { "\(fmt($0.time)) \(fmt($0.value)) \(fmt($0.envelope))" }.joined(separator: " ") }
}
public struct ColorKey: Hashable { public var time: Float, color: Color3, envelope: Float
    public init(_ t: Float, _ c: Color3, _ e: Float) { time = t; color = c; envelope = e } }
public struct ColorSequence: Hashable, CustomStringConvertible {
    public var keys: [ColorKey]
    public init(_ keys: [ColorKey]) { self.keys = keys }
    public var description: String { keys.map { "\(fmt($0.time)) \($0.color)" }.joined(separator: " ") }
}
public struct NumberRange: Hashable, CustomStringConvertible {
    public var min: Float, max: Float
    public init(_ a: Float, _ b: Float) { min = a; max = b }
    public var description: String { "\(fmt(min)) \(fmt(max))" }
}
public struct Rect: Hashable, CustomStringConvertible {
    public var minX: Float, minY: Float, maxX: Float, maxY: Float
    public init(_ a: Float, _ b: Float, _ c: Float, _ d: Float) { minX = a; minY = b; maxX = c; maxY = d }
    public var description: String { "\(fmt(minX)), \(fmt(minY)), \(fmt(maxX)), \(fmt(maxY))" }
}
public struct PhysicalProps: Hashable, CustomStringConvertible {
    /// bit 0: custom properties present, bit 1: acoustic absorption present.
    public var flags: UInt8
    public var density: Float = 0, friction: Float = 0, elasticity: Float = 0
    public var frictionWeight: Float = 0, elasticityWeight: Float = 0, acoustic: Float = 0
    public init(flags: UInt8, density: Float = 0, friction: Float = 0, elasticity: Float = 0,
                frictionWeight: Float = 0, elasticityWeight: Float = 0, acoustic: Float = 0) {
        self.flags = flags; self.density = density; self.friction = friction; self.elasticity = elasticity
        self.frictionWeight = frictionWeight; self.elasticityWeight = elasticityWeight; self.acoustic = acoustic
    }
    public var isCustom: Bool { flags & 1 != 0 }
    public var description: String { isCustom ? "\(fmt(density)), \(fmt(friction)), \(fmt(elasticity))" : "Default" }
}
public struct SharedStr: Hashable { public var bytes: Data; public init(_ b: Data) { bytes = b } }
public struct BinaryString: Hashable, CustomStringConvertible {
    public var bytes: Data; public init(_ b: Data) { bytes = b }
    public var description: String { "<\(bytes.count) bytes>" }
}
public struct OptionalCFrame: Hashable, CustomStringConvertible {
    public var value: CFrame?
    public init(_ v: CFrame?) { value = v }
    public var description: String { value.map(\.description) ?? "nil" }
}
public struct UniqueId: Hashable { public var bytes: Data; public init(_ b: Data) { bytes = b } }
public struct FontValue: Hashable, CustomStringConvertible {
    public var family: String, weight: Int, style: Int, cachedFaceId: String
    public init(_ family: String, _ weight: Int, _ style: Int, _ cached: String) {
        self.family = family; self.weight = weight; self.style = style; cachedFaceId = cached
    }
    public static let `default` = FontValue("rbxasset://fonts/families/SourceSansPro.json", 400, 0, "")
    public var description: String { (family as NSString).lastPathComponent.replacingOccurrences(of: ".json", with: "") }
}
public struct SecurityCaps: Hashable { public var bits: UInt64; public init(_ b: UInt64) { bits = b } }

/// Placeholder for a property whose binary encoding we don't understand; written back verbatim.
public final class RawPropValue: Hashable, CustomStringConvertible {
    public let type: Int, payload: Data, index: Int, count: Int
    public init(type: Int, payload: Data, index: Int, count: Int) {
        self.type = type; self.payload = payload; self.index = index; self.count = count
    }
    public static func == (a: RawPropValue, b: RawPropValue) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
    public var description: String { "<unsupported type 0x\(String(type, radix: 16))>" }
}

/// Every value an Instance property can hold. Mirrors the `Object` values stored in the Android app's prop map.
public enum PropValue: Hashable, CustomStringConvertible {
    case string(String)
    case binaryString(BinaryString)
    case bool(Bool)
    case int(Int32)
    case float(Float)
    case double(Double)
    case int64(Int64)
    case udim(UDim)
    case udim2(UDim2)
    case ray(Ray)
    case faces(Faces)
    case axes(Axes)
    case brickColor(BrickColorV)
    case color3(Color3)
    case vector2(Vector2)
    case vector3(Vector3)
    case cframe(CFrame)
    case enumValue(EnumValue)
    case ref(Instance?)
    case vector3int16(Vector3int16)
    case numberSequence(NumberSequence)
    case colorSequence(ColorSequence)
    case numberRange(NumberRange)
    case rect(Rect)
    case physicalProps(PhysicalProps)
    case sharedString(SharedStr)
    case optionalCFrame(OptionalCFrame)
    case uniqueId(UniqueId)
    case font(FontValue)
    case securityCaps(SecurityCaps)
    case content(ContentValue)
    case raw(RawPropValue)

    public var description: String {
        switch self {
        case .string(let s): return s
        case .binaryString(let v): return v.description
        case .bool(let b): return b ? "true" : "false"
        case .int(let v): return String(v)
        case .float(let v): return fmt(v)
        case .double(let v): return v == v.rounded() && Swift.abs(v) < 1e15 ? String(Int64(v)) : String(v)
        case .int64(let v): return String(v)
        case .udim(let v): return v.description
        case .udim2(let v): return v.description
        case .ray(let v): return v.description
        case .faces(let v): return v.description
        case .axes(let v): return v.description
        case .brickColor(let v): return v.description
        case .color3(let v): return v.description
        case .vector2(let v): return v.description
        case .vector3(let v): return v.description
        case .cframe(let v): return v.description
        case .enumValue(let v): return v.description
        case .ref(let i): return i?.name ?? "nil"
        case .vector3int16(let v): return v.description
        case .numberSequence(let v): return v.description
        case .colorSequence(let v): return v.description
        case .numberRange(let v): return v.description
        case .rect(let v): return v.description
        case .physicalProps(let v): return v.description
        case .sharedString(let v): return "<\(v.bytes.count) bytes>"
        case .optionalCFrame(let v): return v.description
        case .uniqueId: return "<id>"
        case .font(let v): return v.description
        case .securityCaps(let v): return String(v.bits)
        case .content(let v): return v.description
        case .raw(let v): return v.description
        }
    }

    public var asFloat: Float? {
        switch self {
        case .float(let v): return v
        case .double(let v): return Float(v)
        case .int(let v): return Float(v)
        case .int64(let v): return Float(v)
        default: return nil
        }
    }
    public var asString: String? { if case .string(let s) = self { return s }; return nil }
    public var asBool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var asVector3: Vector3? { if case .vector3(let v) = self { return v }; return nil }
    public var asCFrame: CFrame? { if case .cframe(let v) = self { return v }; return nil }
    public var asColor3: Color3? { if case .color3(let v) = self { return v }; return nil }
    public var asEnum: UInt32? { if case .enumValue(let v) = self { return v.value }; return nil }
    public var asInstance: Instance? { if case .ref(let v) = self { return v }; return nil }
    public var asURI: String? {
        switch self {
        case .string(let s): return s
        case .content(let c): return c.sourceType == 1 ? c.uri : ""
        default: return nil
        }
    }
}

/// Content property (type 0x22): either a URI or a reference to an Instance.
public struct ContentValue: Hashable, CustomStringConvertible {
    /// 0 = none, 1 = uri, 2 = object
    public var sourceType: Int
    public var uri: String
    public var obj: Instance?
    public init(sourceType: Int = 0, uri: String = "", obj: Instance? = nil) {
        self.sourceType = sourceType; self.uri = uri; self.obj = obj
    }
    public var description: String {
        switch sourceType {
        case 1: return uri
        case 2: return obj.map { "Object(\($0.name))" } ?? "Object(nil)"
        default: return ""
        }
    }
}

/// Binary type ids, from model/PropType.kt.
public enum PropType {
    public static let STRING = 1, BOOL = 2, INT = 3, FLOAT = 4, DOUBLE = 5, UDIM = 6, UDIM2 = 7, RAY = 8
    public static let FACES = 9, AXES = 10, BRICKCOLOR = 11, COLOR3 = 12, VECTOR2 = 13, VECTOR3 = 14
    public static let CFRAME = 16, ENUM = 18, REF = 19, VECTOR3INT16 = 20, NUMBERSEQ = 21, COLORSEQ = 22
    public static let NUMBERRANGE = 23, RECT = 24, PHYSPROPS = 25, COLOR3U8 = 26, INT64 = 27
    public static let SHAREDSTRING = 28, OPTCFRAME = 30, UNIQUEID = 31, FONT = 32, SECCAPS = 33, CONTENT = 34

    public static func infer(_ v: PropValue) -> Int {
        switch v {
        case .string, .binaryString: return STRING
        case .bool: return BOOL
        case .int: return INT
        case .float: return FLOAT
        case .double: return DOUBLE
        case .int64: return INT64
        case .udim: return UDIM
        case .udim2: return UDIM2
        case .ray: return RAY
        case .faces: return FACES
        case .axes: return AXES
        case .brickColor: return BRICKCOLOR
        case .color3: return COLOR3
        case .vector2: return VECTOR2
        case .vector3: return VECTOR3
        case .cframe: return CFRAME
        case .enumValue: return ENUM
        case .ref: return REF
        case .vector3int16: return VECTOR3INT16
        case .numberSequence: return NUMBERSEQ
        case .colorSequence: return COLORSEQ
        case .numberRange: return NUMBERRANGE
        case .rect: return RECT
        case .physicalProps: return PHYSPROPS
        case .sharedString: return SHAREDSTRING
        case .optionalCFrame: return OPTCFRAME
        case .uniqueId: return UNIQUEID
        case .font: return FONT
        case .securityCaps: return SECCAPS
        case .content: return CONTENT
        case .raw(let r): return r.type
        }
    }

    public static func defaultValue(_ t: Int) -> PropValue {
        switch t {
        case STRING: return .string("")
        case BOOL: return .bool(false)
        case INT: return .int(0)
        case FLOAT: return .float(0)
        case DOUBLE: return .double(0)
        case UDIM: return .udim(UDim(0, 0))
        case UDIM2: return .udim2(UDim2(0, 0, 0, 0))
        case RAY: return .ray(Ray(.zero, .zero))
        case FACES: return .faces(Faces(0))
        case AXES: return .axes(Axes(0))
        case BRICKCOLOR: return .brickColor(BrickColorV(194))
        case COLOR3, COLOR3U8: return .color3(Color3(0, 0, 0))
        case VECTOR2: return .vector2(.zero)
        case VECTOR3: return .vector3(.zero)
        case CFRAME: return .cframe(.identity)
        case ENUM: return .enumValue(EnumValue(0))
        case VECTOR3INT16: return .vector3int16(Vector3int16(0, 0, 0))
        case NUMBERSEQ: return .numberSequence(NumberSequence([NumberKey(0, 0, 0), NumberKey(1, 0, 0)]))
        case COLORSEQ: return .colorSequence(ColorSequence([ColorKey(0, Color3(1, 1, 1), 0), ColorKey(1, Color3(1, 1, 1), 0)]))
        case NUMBERRANGE: return .numberRange(NumberRange(0, 0))
        case RECT: return .rect(Rect(0, 0, 0, 0))
        case PHYSPROPS: return .physicalProps(PhysicalProps(flags: 0))
        case INT64: return .int64(0)
        case SHAREDSTRING: return .sharedString(SharedStr(Data()))
        case OPTCFRAME: return .optionalCFrame(OptionalCFrame(nil))
        case UNIQUEID: return .uniqueId(UniqueId(Data(count: 16)))
        case FONT: return .font(.default)
        case SECCAPS: return .securityCaps(SecurityCaps(0))
        case CONTENT: return .content(ContentValue())
        default: return .ref(nil)
        }
    }

    /// Properties the Properties panel should not show.
    public static func hidden(_ t: Int, _ v: PropValue) -> Bool {
        if t == SHAREDSTRING || t == UNIQUEID || t == SECCAPS { return true }
        switch v { case .binaryString, .raw: return true; default: return false }
    }
}
