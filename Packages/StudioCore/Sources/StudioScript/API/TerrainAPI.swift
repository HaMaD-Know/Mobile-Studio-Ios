import Foundation
import StudioCore

/// Terrain methods for scripts (port of lua/TerrainApi.kt).
enum TerrainAPI {
    static let methods: Set<String> = [
        "FillBall", "FillBlock", "FillCylinder", "FillWedge", "FillRegion", "ReplaceMaterial", "Clear", "CountCells",
        "GetMaterialColor", "SetMaterialColor", "WorldToCell", "WorldToCellPreferSolid", "WorldToCellPreferEmpty",
        "CellCenterToWorld", "CellCornerToWorld", "GetCell", "SetCell", "ConvertToSmooth", "AutowedgeCell", "AutowedgeCells",
    ]

    static func material(_ c: LuaCall, _ i: Int32, _ fn: String) throws -> Int {
        guard let e = c.enumItem(i) else { throw c.argError(i, "Material", fn) }
        let m = TerrainMaterials.fromEnum(e.value)
        guard m >= 0 else { throw LuaError("\(fn): \(e.name) is not a terrain material") }
        return m
    }

    static func pushMaterial(_ c: LuaCall, _ m: Int) {
        let v = m >= 0 && m < TerrainMaterials.enumValues.count ? TerrainMaterials.enumValues[m] : 1792
        if let item = ScriptEnums.item("Material", value: v) { c.push(.enumItem(item)) } else { c.pushNil() }
    }

    static func region(_ c: LuaCall, _ i: Int32, _ fn: String) throws -> Region3 {
        guard case .region3(let r)? = c.object(i) else { throw c.argError(i, "Region3", fn) }
        return r
    }

    static func call(_ c: LuaCall, _ t: Instance, _ m: String) throws -> Int32? {
        guard t.className == "Terrain", methods.contains(m) else { return nil }
        let g = TerrainStore.of(t)
        func changed() {
            g.modified = true
            c.rt.propChanged(t, "SmoothGrid")
        }
        switch m {
        case "FillBall":
            TerrainOps.fillBall(g, center: try c.checkVector3(2, m), radius: try c.checkFloat(3, m), material: try material(c, 4, m))
            changed(); return 0
        case "FillBlock":
            TerrainOps.fillBlock(g, cframe: try c.checkCFrame(2, m), size: try c.checkVector3(3, m), material: try material(c, 4, m))
            changed(); return 0
        case "FillCylinder":
            TerrainOps.fillCylinder(g, cframe: try c.checkCFrame(2, m), height: try c.checkFloat(3, m), radius: try c.checkFloat(4, m),
                                    material: try material(c, 5, m))
            changed(); return 0
        case "FillWedge":
            TerrainOps.fillWedge(g, cframe: try c.checkCFrame(2, m), size: try c.checkVector3(3, m), material: try material(c, 4, m))
            changed(); return 0
        case "FillRegion":
            let r = try region(c, 2, m)
            TerrainOps.fillRegion(g, lo: r.min, hi: r.max, material: try material(c, 4, m))
            changed(); return 0
        case "ReplaceMaterial":
            let r = try region(c, 2, m)
            TerrainOps.replaceMaterial(g, lo: r.min, hi: r.max, from: try material(c, 4, m), to: try material(c, 5, m))
            changed(); return 0
        case "Clear":
            g.clear(); changed(); return 0
        case "CountCells":
            c.push(g.countCells()); return 1
        case "GetMaterialColor":
            let mat = try material(c, 2, m)
            c.push(.color3(TerrainMaterials.colors(t)[mat])); return 1
        case "SetMaterialColor":
            let mat = try material(c, 2, m)
            guard let col = c.color3(3) else { throw c.argError(3, "Color3", m) }
            var colors = TerrainMaterials.colors(t)
            colors[mat] = col
            t.set("MaterialColors", .binaryString(BinaryString(TerrainMaterials.encodeColors(colors))), notify: false)
            c.rt.propChanged(t, "MaterialColors")
            return 0
        case "WorldToCell", "WorldToCellPreferSolid", "WorldToCellPreferEmpty":
            let p = try c.checkVector3(2, m)
            c.push(Vector3(floor(p.x / 4), floor(p.y / 4), floor(p.z / 4))); return 1
        case "CellCenterToWorld":
            c.push(Vector3((try c.checkFloat(2, m) + 0.5) * 4, (try c.checkFloat(3, m) + 0.5) * 4, (try c.checkFloat(4, m) + 0.5) * 4)); return 1
        case "CellCornerToWorld":
            c.push(Vector3(try c.checkFloat(2, m) * 4, try c.checkFloat(3, m) * 4, try c.checkFloat(4, m) * 4)); return 1
        case "GetCell":
            let x = Int(try c.checkFloat(2, m)), y = Int(try c.checkFloat(3, m)), z = Int(try c.checkFloat(4, m))
            pushMaterial(c, g.material(x, y, z)); return 1
        case "SetCell":
            let x = Int(try c.checkFloat(2, m)), y = Int(try c.checkFloat(3, m)), z = Int(try c.checkFloat(4, m))
            let mat = try material(c, 5, m)
            g.set(x, y, z, mat, mat == 0 ? 0 : 1)
            changed(); return 0
        default:
            // ConvertToSmooth / Autowedge: smooth terrain already, nothing to do.
            return 0
        }
    }
}
