import Foundation
import StudioCore

/// Script-facing property names vs the names stored in files (port of model/PropNames.kt).
enum PropAccess {
    static let toDisplay: [String: String] = [
        "size": "Size", "Color3uint8": "Color", "shape": "Shape", "formFactorRaw": "FormFactor", "Health_XML": "Health",
        "MaterialVariantSerialized": "MaterialVariant", "xmlRead_MaxDistance_3": "RollOffMaxDistance",
        "xmlRead_MinDistance_3": "RollOffMinDistance", "BackgroundColor": "BackgroundBrickColor",
        "Font_Serialized": "FontFace", "Use2022MaterialsXml": "Use2022Materials",
    ]
    static let fromDisplay: [String: String] = Dictionary(uniqueKeysWithValues: toDisplay.map { ($1, $0) })

    static func display(_ n: String) -> String { toDisplay[n] ?? n }

    /// The stored key for a script-facing name on this instance.
    static func resolve(_ inst: Instance, _ name: String) -> String {
        if inst.props.contains(name) { return name }
        if let s = fromDisplay[name], inst.props.contains(s) { return s }
        if let s = fromDisplay[name], name == "Size" || name == "Color" || name == "Shape" || name == "Health" { return s }
        return name
    }

    /// Convert a stored property value to a script value (LuaRuntime.toLua).
    static func toScript(_ v: PropValue, _ inst: Instance?, _ prop: String?) -> ScriptValue {
        switch v {
        case .string(let s): return .string(s)
        case .binaryString(let b): return .string(String(decoding: b.bytes, as: UTF8.self))
        case .bool(let b): return .bool(b)
        case .int(let n): return .number(Double(n))
        case .float(let f): return .number(Double(f))
        case .double(let d): return .number(d)
        case .int64(let n): return .number(Double(n))
        case .udim(let u): return .object(.udim(u))
        case .udim2(let u): return .object(.udim2(u))
        case .ray(let r): return .object(.ray(r))
        case .faces(let f): return .object(.faces(f))
        case .axes(let a): return .object(.axes(a))
        case .brickColor(let b): return .object(.brickColor(Int(b.number)))
        case .color3(let c): return .object(.color3(c))
        case .vector2(let x): return .object(.vector2(x))
        case .vector3(let x): return .object(.vector3(x))
        case .cframe(let x): return .object(.cframe(x))
        case .enumValue(let e):
            if let prop, let t = enumType(inst, prop), let it = ScriptEnums.item(t, value: Int(e.value)) { return .object(.enumItem(it)) }
            return .number(Double(e.value))
        case .ref(let i): return i.map { .object(.instance($0)) } ?? .nil_
        case .vector3int16(let x): return .object(.vector3int16(x))
        case .numberSequence(let s): return .object(.numberSequence(s))
        case .colorSequence(let s): return .object(.colorSequence(s))
        case .numberRange(let r): return .object(.numberRange(r))
        case .rect(let r): return .object(.rect(r))
        case .physicalProps(let p): return p.isCustom ? .object(.physicalProps(p)) : .nil_
        case .sharedString(let s): return .string(String(decoding: s.bytes, as: UTF8.self))
        case .optionalCFrame(let o): return o.value.map { .object(.cframe($0)) } ?? .nil_
        case .uniqueId, .securityCaps, .raw: return .nil_
        case .font(let f): return .object(.font(f))
        case .content(let c): return c.sourceType == 2 ? (c.obj.map { .object(.instance($0)) } ?? .nil_) : .string(c.uri)
        }
    }

    /// Enum type name for a property, by name (Enums.typeForProp + common Roblox properties).
    static func enumType(_ inst: Instance?, _ prop: String) -> String? {
        if let t = Enums.typeForProp(prop) { return t }
        switch prop {
        case "EasingStyle": return "EasingStyle"
        case "EasingDirection": return "EasingDirection"
        case "PlaybackState": return "PlaybackState"
        case "MouseBehavior": return "MouseBehavior"
        case "RollOffMode": return "RollOffMode"
        case "ActuatorType", "AngularActuatorType", "LinearActuatorType": return "ActuatorType"
        case "Style" where inst?.className == "ProximityPrompt": return "ProximityPromptStyle"
        case "Exclusivity": return "ProximityPromptExclusivity"
        case "TextTruncate": return "TextTruncate"
        case "ParticleEmitterShape", "Shape" where inst?.className == "ParticleEmitter": return "ParticleEmitterShape"
        case "Orientation" where inst?.className == "ParticleEmitter": return "ParticleOrientation"
        case "SizeConstraint": return "SizeConstraint"
        case "StartCorner": return "StartCorner"
        case "Priority" where inst?.className == "Animation": return "AnimationPriority"
        case "RigType": return "HumanoidRigType"
        case "DisplayDistanceType": return "HumanoidDisplayDistanceType"
        case "HealthDisplayType": return "HumanoidHealthDisplayType"
        case "DevTouchMovementMode": return "DevTouchMovementMode"
        case "FilterType": return "RaycastFilterType"
        case "FloorMaterial": return "Material"
        case "ExplosionType": return "ExplosionType"
        case "Face", "TargetSurface": return "NormalId"
        case "FontSize", "Font": return "Font"
        default: return nil
        }
    }

    /// Convert a script value into a property value, shaped like `existing` when present (LuaRuntime.fromLua).
    static func fromScript(_ v: ScriptValue, existing: PropValue?, type: Int?, inst: Instance, prop: String) throws -> PropValue {
        let t = type ?? existing.map(PropType.infer)
        switch (t, v) {
        case (PropType.OPTCFRAME?, .nil_): return .optionalCFrame(OptionalCFrame(nil))
        case (PropType.OPTCFRAME?, .object(.cframe(let c))): return .optionalCFrame(OptionalCFrame(c))
        case (PropType.REF?, .nil_), (nil, .nil_): return .ref(nil)
        case (_, .nil_):
            if case .content? = existing { return .content(ContentValue()) }
            if t == PropType.STRING { return .string("") }
            return .ref(nil)
        case (PropType.BOOL?, _): return .bool(truthy(v))
        case (PropType.INT?, .number(let n)): return .int(Int32(clamping: Int64(n.isFinite ? n : 0)))
        case (PropType.INT?, .object(.enumItem(let e))): return .int(Int32(e.value))
        case (PropType.FLOAT?, .number(let n)): return .float(Float(n))
        case (PropType.DOUBLE?, .number(let n)): return .double(n)
        case (PropType.INT64?, .number(let n)): return .int64(Int64(n.isFinite ? n : 0))
        case (PropType.STRING?, .string(let s)): return .string(s)
        case (PropType.STRING?, .number(let n)): return .string(n == n.rounded() ? String(Int64(n)) : String(n))
        case (PropType.CONTENT?, .string(let s)): return .content(s.isEmpty ? ContentValue() : ContentValue(sourceType: 1, uri: s))
        case (PropType.CONTENT?, .object(.instance(let i))): return .content(ContentValue(sourceType: 2, uri: "", obj: i))
        case (PropType.ENUM?, .object(.enumItem(let e))): return .enumValue(EnumValue(UInt32(max(0, e.value))))
        case (PropType.ENUM?, .number(let n)): return .enumValue(EnumValue(UInt32(max(0, n))))
        case (PropType.ENUM?, .string(let s)):
            guard let et = enumType(inst, prop), let it = ScriptEnums.item(et, s) else {
                throw LuaError("Invalid value \"\(s)\" for enum \(enumType(inst, prop) ?? "?")")
            }
            return .enumValue(EnumValue(UInt32(it.value)))
        case (PropType.BRICKCOLOR?, .object(.brickColor(let n))): return .brickColor(BrickColorV(Int32(n)))
        case (PropType.BRICKCOLOR?, .object(.color3(let c))): return .brickColor(BrickColorV(Int32(BrickColors.closest(c))))
        case (PropType.COLOR3?, .object(.color3(let c))), (PropType.COLOR3U8?, .object(.color3(let c))): return .color3(c)
        case (PropType.COLOR3?, .object(.brickColor(let n))), (PropType.COLOR3U8?, .object(.brickColor(let n))): return .color3(BrickColors.color(n))
        case (PropType.REF?, .object(.instance(let i))): return .ref(i)
        case (PropType.VECTOR3?, .object(.vector3(let x))): return .vector3(x)
        case (PropType.CFRAME?, .object(.cframe(let x))): return .cframe(x)
        case (PropType.UDIM2?, .object(.udim2(let x))): return .udim2(x)
        case (PropType.UDIM?, .object(.udim(let x))): return .udim(x)
        case (PropType.VECTOR2?, .object(.vector2(let x))): return .vector2(x)
        default:
            if let t, [PropType.VECTOR3, PropType.CFRAME, PropType.COLOR3, PropType.COLOR3U8, PropType.UDIM2, PropType.REF].contains(t),
               case .object(let o) = v, case .instance = o {
                throw LuaError("Unable to assign property \(prop). \(expectedName(t)) expected, got Instance")
            }
            return try plain(v, prop: prop)
        }
    }

    private static func expectedName(_ t: Int) -> String {
        switch t {
        case PropType.VECTOR3: "Vector3"
        case PropType.CFRAME: "CFrame"
        case PropType.COLOR3, PropType.COLOR3U8: "Color3"
        case PropType.UDIM2: "UDim2"
        default: "Object"
        }
    }

    /// Untyped conversion (new properties, attributes).
    static func plain(_ v: ScriptValue, prop: String) throws -> PropValue {
        switch v {
        case .nil_: return .ref(nil)
        case .bool(let b): return .bool(b)
        case .number(let n): return .double(n)
        case .string(let s): return .string(s)
        case .object(let o):
            switch o {
            case .instance(let i): return .ref(i)
            case .vector3(let x): return .vector3(x)
            case .vector2(let x): return .vector2(x)
            case .cframe(let x): return .cframe(x)
            case .color3(let x): return .color3(x)
            case .brickColor(let n): return .brickColor(BrickColorV(Int32(n)))
            case .udim(let x): return .udim(x)
            case .udim2(let x): return .udim2(x)
            case .ray(let x): return .ray(x)
            case .rect(let x): return .rect(x)
            case .numberRange(let x): return .numberRange(x)
            case .numberSequence(let x): return .numberSequence(x)
            case .colorSequence(let x): return .colorSequence(x)
            case .vector3int16(let x): return .vector3int16(x)
            case .physicalProps(let x): return .physicalProps(x)
            case .font(let x): return .font(x)
            case .faces(let x): return .faces(x)
            case .axes(let x): return .axes(x)
            case .enumItem(let e): return .enumValue(EnumValue(UInt32(max(0, e.value))))
            default: throw LuaError("Unable to assign property \(prop). Value of type \(o.typeName) can't be stored")
            }
        default: throw LuaError("Unable to assign property \(prop). Value of type table/function can't be stored")
        }
    }

    static func truthy(_ v: ScriptValue) -> Bool {
        switch v {
        case .nil_: return false
        case .bool(let b): return b
        default: return true
        }
    }
}
