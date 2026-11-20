import Foundation

/// Creates instances with sensible default properties (port of model/InstanceFactory.kt).
/// Phase 1 ports the defaults for parts, scripts, models, lights, values and the common
/// services; the long per-class `extraDefaults` table (sound effects, constraints, GUI
/// layout objects...) is still TODO.
public enum InstanceFactory {
    static let grey = Color3.fromRGB(163, 162, 165)

    public static func create(_ cls: String) -> Instance {
        let i = Instance(cls)
        func s(_ n: String, _ v: PropValue) { i.set(n, v, notify: false) }
        s("Name", .string(cls))
        if ClassDb.isServiceName(cls) { i.isService = true }

        if ClassDb.isA(cls, "BasePart") {
            part(i, cls)
        } else if ClassDb.isA(cls, "LuaSourceContainer") {
            s("Source", .string(cls == "ModuleScript" ? "local module = {}\n\nreturn module\n" : "print(\"Hello world!\")\n"))
            if cls != "ModuleScript" { s("Disabled", .bool(false)) }
        } else if cls == "Model" {
            s("WorldPivotData", .optionalCFrame(OptionalCFrame(nil)))
            s("PrimaryPart", .ref(nil))
        } else if cls == "Humanoid" {
            s("Health_XML", .float(100)); s("MaxHealth", .float(100)); s("WalkSpeed", .float(16))
            s("JumpPower", .float(50)); s("HipHeight", .float(0)); s("DisplayName", .string(""))
        } else if ClassDb.isA(cls, "GuiObject") {
            s("Size", .udim2(UDim2(0, 100, 0, 100))); s("Position", .udim2(UDim2(0, 0, 0, 0)))
            s("BackgroundColor3", .color3(Color3(1, 1, 1))); s("BackgroundTransparency", .float(0))
            s("Visible", .bool(true)); s("ZIndex", .int(1))
            if cls.hasPrefix("Text") {
                s("Text", .string(cls == "TextBox" ? "" : cls)); s("TextColor3", .color3(Color3(0, 0, 0)))
                s("TextSize", .float(14)); s("FontFace", .font(.default))
            }
            if cls.hasPrefix("Image") { s("Image", .string("")) }
        } else if cls == "ScreenGui" {
            s("Enabled", .bool(true)); s("ResetOnSpawn", .bool(true)); s("IgnoreGuiInset", .bool(false))
        } else if ClassDb.isA(cls, "Light") {
            s("Brightness", .float(1)); s("Color", .color3(Color3(1, 1, 1))); s("Range", .float(8))
            s("Enabled", .bool(true)); s("Shadows", .bool(false))
        } else if cls == "StringValue" { s("Value", .string(""))
        } else if cls == "IntValue" { s("Value", .int64(0))
        } else if cls == "NumberValue" { s("Value", .double(0))
        } else if cls == "BoolValue" { s("Value", .bool(false))
        } else if cls == "ObjectValue" { s("Value", .ref(nil))
        } else if cls == "Vector3Value" { s("Value", .vector3(.zero))
        } else if cls == "CFrameValue" { s("Value", .cframe(.identity))
        } else if cls == "Color3Value" { s("Value", .color3(Color3(0, 0, 0)))
        } else if cls == "Sound" {
            s("SoundId", .string("")); s("Volume", .float(0.5)); s("Looped", .bool(false)); s("Playing", .bool(false))
        } else if cls == "UICorner" { s("CornerRadius", .udim(UDim(0, 8)))
        } else if cls == "UIStroke" {
            s("Color", .color3(Color3(0, 0, 0))); s("Thickness", .float(1)); s("Transparency", .float(0))
        } else if cls == "UIListLayout" {
            s("Padding", .udim(UDim(0, 0))); s("FillDirection", .enumValue(EnumValue(1))); s("SortOrder", .enumValue(EnumValue(2)))
        } else if cls == "UIPadding" {
            for n in ["PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight"] { s(n, .udim(UDim(0, 0))) }
        } else if cls == "Attachment" { s("CFrame", .cframe(.identity))
        } else if cls == "Weld" || cls == "Motor6D" {
            s("Part0", .ref(nil)); s("Part1", .ref(nil)); s("C0", .cframe(.identity)); s("C1", .cframe(.identity))
        } else if cls == "WeldConstraint" {
            s("Part0Internal", .ref(nil)); s("Part1Internal", .ref(nil))
        } else if cls == "ClickDetector" { s("MaxActivationDistance", .float(32))
        } else if cls == "Decal" || cls == "Texture" {
            s("Texture", .string("")); s("Face", .enumValue(EnumValue(5))); s("Transparency", .float(0))
        } else if cls == "SpecialMesh" {
            s("MeshType", .enumValue(EnumValue(6))); s("Scale", .vector3(.one)); s("MeshId", .string(""))
        } else if cls == "Tool" {
            s("RequiresHandle", .bool(true)); s("CanBeDropped", .bool(true)); s("ToolTip", .string(""))
        } else if cls == "Camera" {
            s("CFrame", .cframe(.identity)); s("FieldOfView", .float(70)); s("CameraType", .enumValue(EnumValue(0)))
        } else if cls == "Lighting" {
            s("ClockTime", .float(14)); s("Brightness", .float(2))
            s("Ambient", .color3(.fromRGB(70, 70, 70))); s("OutdoorAmbient", .color3(.fromRGB(128, 128, 128)))
        } else if cls == "Workspace" {
            s("Gravity", .float(196.2)); s("FallenPartsDestroyHeight", .float(-500))
        } else if cls == "Players" {
            s("MaxPlayers", .int(12)); s("RespawnTime", .float(5))
        } else if cls == "ProximityPrompt" {
            s("ActionText", .string("Interact")); s("ObjectText", .string(""))
            s("MaxActivationDistance", .float(10)); s("HoldDuration", .float(0))
        } else if cls == "ParticleEmitter" { s("Rate", .float(20)); s("Enabled", .bool(true))
        } else if cls == "Highlight" {
            s("FillColor", .color3(Color3(1, 0, 0))); s("OutlineColor", .color3(Color3(1, 1, 1)))
            s("FillTransparency", .float(0.5)); s("Enabled", .bool(true))
        } else if cls == "BillboardGui" || cls == "SurfaceGui" {
            s("Enabled", .bool(true)); s("Adornee", .ref(nil))
        } else if cls == "Team" { s("TeamColor", .brickColor(BrickColorV(194))); s("AutoAssignable", .bool(true))
        } else if cls == "Animation" { s("AnimationId", .string(""))
        } else if cls == "MaterialService" {
            s("Use2022MaterialsXml", .bool(true))
            for (name, _) in Enums.items("Material") where !["Air", "Water", "Neon", "Glass", "ForceField"].contains(name) {
                s(name + "Name", .string(name))
            }
        }
        if ClassDb.isA(cls, "Constraint") {
            for (n, v) in [("Attachment0", PropValue.ref(nil)), ("Attachment1", .ref(nil)), ("Enabled", .bool(true)),
                           ("Color", .brickColor(BrickColorV(194)))] where !i.props.contains(n) { s(n, v) }
        }
        return i
    }

    private static func part(_ i: Instance, _ cls: String) {
        func s(_ n: String, _ v: PropValue) { i.set(n, v, notify: false) }
        s("Anchored", .bool(false)); s("CanCollide", .bool(true)); s("CanTouch", .bool(true)); s("CanQuery", .bool(true))
        s("CastShadow", .bool(true)); s("Locked", .bool(false)); s("Massless", .bool(false))
        s("CFrame", .cframe(.identity)); s("Transparency", .float(0)); s("Reflectance", .float(0))
        s("Material", .enumValue(EnumValue(256)))
        s("Color3uint8", .color3(grey)); i.propTypes["Color3uint8"] = PropType.COLOR3U8
        s("size", .vector3(Vector3(4, 1, 2)))
        for n in ["TopSurface", "BottomSurface", "FrontSurface", "BackSurface", "LeftSurface", "RightSurface"] {
            s(n, .enumValue(EnumValue(0)))
        }
        switch cls {
        case "Part", "Seat", "SpawnLocation": s("shape", .enumValue(EnumValue(1)))
        case "TrussPart": s("size", .vector3(Vector3(2, 10, 2)))
        case "MeshPart": s("MeshId", .string("")); s("TextureID", .string(""))
        default: break
        }
        if cls == "SpawnLocation" {
            s("size", .vector3(Vector3(12, 1, 12))); s("Anchored", .bool(true)); s("Duration", .int(10))
            s("Neutral", .bool(true)); s("Enabled", .bool(true))
        }
    }
}

/// Typed accessors for BasePart properties (port of model/PartData.kt).
public enum PartData {
    public enum Shape: Int { case ball = 0, block = 1, cylinder = 2, wedge = 3, cornerWedge = 4 }

    public static func cframe(_ p: Instance) -> CFrame { p.get("CFrame")?.asCFrame ?? .identity }
    public static func size(_ p: Instance) -> Vector3 {
        (p.get("size") ?? p.get("Size"))?.asVector3 ?? Vector3(4, 1, 2)
    }
    public static func color(_ p: Instance) -> Color3 {
        if let c = p.get("Color3uint8")?.asColor3 { return c }
        if let c = p.get("Color")?.asColor3 { return c }
        if case .brickColor(let b)? = p.get("BrickColor") { return b.color }
        return .fromRGB(163, 162, 165)
    }
    public static func transparency(_ p: Instance) -> Float { p.get("Transparency")?.asFloat ?? 0 }
    public static func material(_ p: Instance) -> Int { Int(p.get("Material")?.asEnum ?? 256) }

    public static func content(_ p: Instance, _ keys: String...) -> String? {
        for k in keys {
            guard let v = p.get(k) else { continue }
            let s = v.description
            if !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        }
        return nil
    }
    public static func meshContent(_ p: Instance) -> String? { content(p, "MeshId", "MeshID", "MeshContent") }
    public static func textureContent(_ p: Instance) -> String? { content(p, "TextureID", "TextureId", "TextureContent") }

    public static func shape(_ p: Instance) -> Shape {
        if p.className == "WedgePart" { return .wedge }
        if p.className == "CornerWedgePart" { return .cornerWedge }
        if let v = (p.get("shape") ?? p.get("Shape"))?.asEnum { return Shape(rawValue: Int(v)) ?? .block }
        if let mesh = p.children.first(where: { $0.className == "SpecialMesh" }) {
            let t = mesh.get("MeshType")?.asEnum
            if t == 3 { return .ball }
            if t == 2 { return .wedge }
            return .block
        }
        return .block
    }

    public static func setCFrame(_ p: Instance, _ cf: CFrame) { p.set("CFrame", .cframe(cf)) }
    public static func setSize(_ p: Instance, _ s: Vector3) {
        if !p.props.contains("Size") || p.props.contains("size") { p.set("size", .vector3(s)) } else { p.set("Size", .vector3(s)) }
    }
    public static func setColor(_ p: Instance, _ c: Color3) {
        if p.props.contains("Color3uint8") || !p.props.contains("Color") {
            p.set("Color3uint8", .color3(c))
            p.propTypes["Color3uint8"] = PropType.COLOR3U8
        } else {
            p.set("Color", .color3(c))
        }
    }
}
