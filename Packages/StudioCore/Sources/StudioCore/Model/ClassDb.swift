import Foundation

/// Class hierarchy knowledge (port of model/ClassDb.kt). Tables live in Generated/ClassDbTable.swift.
public enum ClassDb {
    static let parents: [String: String] = {
        var m: [String: String] = [:]
        for (c, b) in ClassDbTable.parents { m[c] = b }
        return m
    }()

    public static var serviceNames: [String] { ClassDbTable.serviceNames }
    public static var insertable: [String] { ClassDbTable.insertable }

    public static func superclass(_ c: String) -> String? {
        if let p = parents[c] { return p }
        return c == "Instance" ? nil : "Instance"
    }

    public static func isA(_ c: String, _ target: String) -> Bool {
        if target == "Instance" { return true }
        var cur = c
        for _ in 0..<20 {
            if cur == target { return true }
            if cur == "Instance" { return false }
            cur = parents[cur] ?? "Instance"
        }
        return false
    }

    public static func isServiceName(_ n: String) -> Bool {
        ClassDbTable.serviceNames.contains(n) || ClassDbTable.otherServices.contains(n)
    }
}

/// BrickColor palette (port of model/BrickColors.kt).
public enum BrickColors {
    static let table: [Int: (String, Int)] = {
        var m: [Int: (String, Int)] = [:]
        for (n, name, rgb) in BrickColorTable.entries { m[n] = (name, rgb) }
        return m
    }()
    public static var all: [Int] { BrickColorTable.entries.map(\.0) }
    public static func name(_ n: Int) -> String { table[n]?.0 ?? "Medium stone grey" }
    public static func color(_ n: Int) -> Color3 { Color3.fromHex(table[n]?.1 ?? 0xA3A2A5) }
    public static func byName(_ s: String) -> Int? {
        BrickColorTable.entries.first { $0.1.caseInsensitiveCompare(s) == .orderedSame }?.0
    }
    public static func closest(_ c: Color3) -> Int {
        var best = 194, bd = Float.greatestFiniteMagnitude
        for (n, _, rgb) in BrickColorTable.entries {
            let o = Color3.fromHex(rgb)
            let d = (o.r - c.r) * (o.r - c.r) + (o.g - c.g) * (o.g - c.g) + (o.b - c.b) * (o.b - c.b)
            if d < bd { bd = d; best = n }
        }
        return best
    }
}

/// Enum names (port of model/Enums.kt).
public enum Enums {
    public static func items(_ enumType: String) -> [(String, Int)] { EnumTable.types[enumType] ?? [] }

    public static func itemName(_ enumType: String, _ value: Int) -> String? {
        items(enumType).first { $0.1 == value }?.0
    }

    /// Which enum type a property holds, by property name (Enums.typeForProp in the Android app).
    public static func typeForProp(_ prop: String) -> String? {
        switch prop {
        case "Material", "BaseMaterial": return "Material"
        case "TopSurface", "BottomSurface", "FrontSurface", "BackSurface", "LeftSurface", "RightSurface": return "SurfaceType"
        case "Shape", "shape": return "PartType"
        case "FormFactor", "formFactorRaw": return "FormFactor"
        case "Face": return "NormalId"
        case "RigType": return "HumanoidRigType"
        case "GameSettingsR15Collision": return "R15CollisionType"
        case "GameSettingsAvatar": return "GameAvatarType"
        case "DepthMode": return "HighlightDepthMode"
        case "ScreenInsets", "HorizontalAlignment", "VerticalAlignment", "AutomaticSize", "CollisionFidelity",
             "BorderMode", "MeshType", "ScrollingDirection", "ApplyStrokeMode", "CameraMode", "CameraType", "Font",
             "ScaleType", "Technology", "TextYAlignment", "RenderFidelity", "ZIndexBehavior", "TextXAlignment",
             "RunContext", "FluidFidelity", "MaterialPattern", "SortOrder", "FillDirection":
            return prop
        default: return nil
        }
    }

    /// Display name for an enum property value, falling back to the raw number.
    public static func display(prop: String, value: UInt32) -> String {
        if let t = typeForProp(prop), let n = itemName(t, Int(value)) { return n }
        return String(value)
    }
}
