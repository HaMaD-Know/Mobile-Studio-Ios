import Foundation

/// New-place templates and document -> DataModel conversion (port of core/PlaceFactory.kt).
public enum PlaceFactory {
    public static let spawnDecalTexture = "rbxasset://textures/SpawnLocation.png"

    public enum Template: CaseIterable, Identifiable {
        case baseplate, classic, flatTerrain, empty, obby, arena, island, village

        public var id: Self { self }

        public var title: String {
            switch self {
            case .baseplate: "Baseplate"
            case .classic: "Classic Baseplate"
            case .flatTerrain: "Flat Terrain"
            case .empty: "Empty Place"
            case .obby: "Obby"
            case .arena: "Team/FFA Arena"
            case .island: "Island"
            case .village: "Village"
            }
        }

        public var subtitle: String {
            switch self {
            case .baseplate: "A large baseplate, a spawn and Studio's current lighting"
            case .classic: "The classic studded baseplate and lighting"
            case .flatTerrain: "A big flat grass terrain to build on"
            case .empty: "Just a spawn location, no ground"
            case .obby: "Jumps, kill bricks, checkpoints, moving and spinning obstacles"
            case .arena: "Two teams, an arena with cover, and a kill leaderboard"
            case .island: "A generated terrain island in the sea"
            case .village: "Houses, trees and paths on grass terrain"
            }
        }

        public var category: String {
            switch self {
            case .baseplate, .classic, .flatTerrain, .empty: "All Templates"
            case .obby, .arena: "Gameplay"
            case .island, .village: "Theme"
            }
        }
    }

    static let required = ["Workspace", "Players", "Lighting", "MaterialService", "ReplicatedFirst", "ReplicatedStorage",
                           "ServerScriptService", "ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "Teams",
                           "SoundService", "TextChatService"]

    /// java.util.Random (48-bit LCG) so Arena/Village layouts match the Android app identically.
    private struct JavaRandom {
        private var seed: UInt64

        init(_ seed: Int64) {
            self.seed = (UInt64(bitPattern: seed) ^ 0x5DEECE66D) & ((1 << 48) - 1)
        }

        private mutating func next(_ bits: Int) -> UInt32 {
            seed = (seed &* 0x5DEECE66D &+ 0xB) & ((1 << 48) - 1)
            return UInt32(seed >> (48 - bits))
        }

        mutating func nextFloat() -> Float {
            Float(next(24)) / Float(1 << 24)
        }

        mutating func nextInt(_ bound: Int) -> Int {
            precondition(bound > 0)
            if (bound & -bound) == bound {
                return Int((UInt64(bound) &* UInt64(next(31))) >> 31)
            }
            let b = Int32(bound)
            while true {
                let bits = Int32(next(31))
                let val = bits % b
                if bits &- val &+ (b &- 1) >= 0 { return Int(val) }
            }
        }
    }

    public static func newPlace(_ template: Template = .baseplate) -> DataModel {
        let dm = DataModel()
        dm.meta["ExplicitAutoJoints"] = "true"
        for s in required { _ = service(dm, s) }
        let ws = dm.findService("Workspace")!

        let cam = InstanceFactory.create("Camera")
        cam.set("CFrame", .cframe(.lookAt(Vector3(0, 20, 40), .zero)), notify: false)
        cam.attachRaw(ws)
        ws.set("CurrentCamera", .ref(cam), notify: false)
        ensureTerrain(ws)

        let sp = dm.findService("StarterPlayer")!
        InstanceFactory.create("StarterPlayerScripts").attachRaw(sp)
        InstanceFactory.create("StarterCharacterScripts").attachRaw(sp)

        let lighting = dm.findService("Lighting")!
        if template == .classic {
            classicLighting(lighting)
        } else {
            modernLighting(lighting)
        }

        switch template {
        case .baseplate:
            baseplate(ws)
            _ = spawn(ws, at: Vector3(0, 0.5, 0))
        case .classic:
            let bp = part(ws, "Baseplate", size: Vector3(512, 20, 512), cf: .at(Vector3(0, -10, 0)),
                          color: .fromRGB(99, 95, 98))
            bp.set("TopSurface", .enumValue(EnumValue(3)), notify: false)
            bp.set("Locked", .bool(true), notify: false)
            _ = spawn(ws, at: Vector3(0, 0.5, 0))
        case .empty:
            _ = spawn(ws, at: Vector3(0, 0.5, 0))
        case .flatTerrain:
            flatTerrain(ws, size: 512)
            _ = spawn(ws, at: Vector3(0, 0.5, 0))
        case .obby:
            obby(dm, ws)
        case .arena:
            arena(dm, ws)
        case .island:
            island(ws, cam)
        case .village:
            village(ws)
        }
        return dm
    }

    // MARK: helpers

    @discardableResult
    private static func part(_ parent: Instance, _ name: String, size: Vector3, cf: CFrame, color: Color3,
                             material: UInt32 = 256, cls: String = "Part") -> Instance {
        let p = InstanceFactory.create(cls)
        p.name = name
        p.set("Anchored", .bool(true), notify: false)
        p.set("size", .vector3(size), notify: false)
        p.set("CFrame", .cframe(cf), notify: false)
        p.set("Color3uint8", .color3(color), notify: false)
        p.set("Material", .enumValue(EnumValue(material)), notify: false)
        p.attachRaw(parent)
        return p
    }

    @discardableResult
    private static func model(_ parent: Instance, _ name: String) -> Instance {
        let m = InstanceFactory.create("Model")
        m.name = name
        m.attachRaw(parent)
        return m
    }

    @discardableResult
    private static func script(_ parent: Instance, _ name: String, source: String, cls: String = "Script") -> Instance {
        let s = InstanceFactory.create(cls)
        s.name = name
        s.set("Source", .string(source + "\n"), notify: false)
        s.attachRaw(parent)
        return s
    }

    @discardableResult
    private static func spawn(_ parent: Instance, at: Vector3, color: Color3 = .fromRGB(163, 162, 165)) -> Instance {
        let s = InstanceFactory.create("SpawnLocation")
        s.set("CFrame", .cframe(.at(at)), notify: false)
        s.set("Color3uint8", .color3(color), notify: false)
        spawnDecal(s)
        s.attachRaw(parent)
        return s
    }

    public static func spawnDecal(_ spawn: Instance) {
        if spawn.children.contains(where: { $0.className == "Decal" }) { return }
        let d = InstanceFactory.create("Decal")
        d.name = "Decal"
        d.set("Texture", .string(spawnDecalTexture), notify: false)
        d.set("Face", .enumValue(EnumValue(1)), notify: false)
        d.attachRaw(spawn)
    }

    private static func baseplate(_ ws: Instance) {
        let bp = part(ws, "Baseplate", size: Vector3(2048, 16, 2048), cf: .at(Vector3(0, -8, 0)),
                      color: .fromRGB(91, 93, 105))
        bp.set("Locked", .bool(true), notify: false)
        let tex = InstanceFactory.create("Texture")
        tex.name = "Texture"
        tex.set("Texture", .string("rbxassetid://6372755229"), notify: false)
        tex.set("Face", .enumValue(EnumValue(1)), notify: false)
        tex.set("StudsPerTileU", .float(8), notify: false)
        tex.set("StudsPerTileV", .float(8), notify: false)
        tex.set("Transparency", .float(0.8), notify: false)
        tex.attachRaw(bp)
    }

    private static func modernLighting(_ l: Instance) {
        l.set("Ambient", .color3(.fromRGB(70, 70, 70)), notify: false)
        l.set("OutdoorAmbient", .color3(.fromRGB(70, 70, 70)), notify: false)
        l.set("Brightness", .float(3), notify: false)
        l.set("ClockTime", .float(14.5), notify: false)
        l.set("EnvironmentDiffuseScale", .float(1), notify: false)
        l.set("EnvironmentSpecularScale", .float(1), notify: false)
        l.set("GlobalShadows", .bool(true), notify: false)
        l.set("ShadowSoftness", .float(0.2), notify: false)
        l.set("Technology", .enumValue(EnumValue(3)), notify: false)
        let sky = InstanceFactory.create("Sky"); sky.name = "Sky"; sky.attachRaw(l)
        let atm = InstanceFactory.create("Atmosphere"); atm.name = "Atmosphere"
        atm.set("Density", .float(0.3), notify: false); atm.set("Offset", .float(0.25), notify: false); atm.attachRaw(l)
        let bloom = InstanceFactory.create("BloomEffect"); bloom.name = "Bloom"
        bloom.set("Intensity", .float(1), notify: false); bloom.set("Size", .float(24), notify: false)
        bloom.set("Threshold", .float(2), notify: false); bloom.attachRaw(l)
        let dof = InstanceFactory.create("DepthOfFieldEffect"); dof.name = "DepthOfField"
        dof.set("Enabled", .bool(false), notify: false); dof.attachRaw(l)
        let rays = InstanceFactory.create("SunRaysEffect"); rays.name = "SunRays"
        rays.set("Intensity", .float(0.01), notify: false); rays.set("Spread", .float(0.1), notify: false); rays.attachRaw(l)
    }

    private static func classicLighting(_ l: Instance) {
        l.set("Ambient", .color3(.fromRGB(0, 0, 0)), notify: false)
        l.set("OutdoorAmbient", .color3(.fromRGB(127, 127, 127)), notify: false)
        l.set("Brightness", .float(2), notify: false)
        l.set("ClockTime", .float(14), notify: false)
        l.set("GlobalShadows", .bool(true), notify: false)
        l.set("Technology", .enumValue(EnumValue(1)), notify: false)
        let sky = InstanceFactory.create("Sky"); sky.name = "Sky"; sky.attachRaw(l)
    }

    private static func terrain(_ ws: Instance) -> Instance {
        ws.findFirstChildOfClass("Terrain")!
    }

    private static func flatTerrain(_ ws: Instance, size: Float) {
        let t = terrain(ws)
        TerrainOps.fillBlock(TerrainStore.of(t), cframe: .at(Vector3(0, -8, 0)),
                             size: Vector3(size, 16, size), material: TerrainMaterials.fromName("Grass"))
        TerrainStore.flush(t)
    }

    // MARK: templates

    private static func obby(_ dm: DataModel, _ ws: Instance) {
        let course = model(ws, "Obby")
        let stone = Color3.fromRGB(99, 95, 98)
        let green = Color3.fromRGB(75, 151, 75)
        let gold = Color3.fromRGB(245, 205, 48)

        let start = part(course, "Start", size: Vector3(24, 2, 24), cf: .at(Vector3(0, -1, 0)), color: stone, material: 816)
        start.set("TopSurface", .enumValue(EnumValue(0)), notify: false)
        let cp0 = spawn(course, at: Vector3(0, 0.5, 0), color: green)
        cp0.name = "Checkpoint0"; cp0.set("Duration", .int(0), notify: false)

        let lava = part(course, "Lava", size: Vector3(400, 2, 600), cf: .at(Vector3(0, -40, 200)),
                        color: .fromRGB(255, 89, 0), material: 288)
        lava.set("CanCollide", .bool(false), notify: false)
        let kill0 = InstanceFactory.create("BoolValue"); kill0.name = "KillPart"; kill0.attachRaw(lava)

        var z: Float = 20
        let colors: [Color3] = [.fromRGB(13, 105, 172), .fromRGB(196, 40, 28), .fromRGB(245, 205, 48), .fromRGB(75, 151, 75)]
        for i in 0..<6 {
            z += 9
            part(course, "Jump\(i)", size: Vector3(6, 1, 6),
                 cf: .at(Vector3(Float((i % 2) * 2 - 1) * 4, Float(i) * 1.5, z)),
                 color: colors[i % colors.count], material: 272)
        }

        z += 14
        part(course, "Landing1", size: Vector3(16, 2, 16), cf: .at(Vector3(0, 7, z)), color: stone, material: 816)
        let cp1 = spawn(course, at: Vector3(0, 8.5, z), color: green)
        cp1.name = "Checkpoint1"; cp1.set("Duration", .int(0), notify: false)

        z += 8
        part(course, "Bridge", size: Vector3(10, 1, 40), cf: .at(Vector3(0, 7.5, z + 20)),
             color: .fromRGB(163, 162, 165), material: 512)
        for i in 0..<4 {
            let kb = part(course, "KillBrick\(i)", size: Vector3(10, 0.4, 2),
                          cf: .at(Vector3(0, 8.2, z + 6 + Float(i) * 9)), color: .fromRGB(255, 0, 0), material: 288)
            let kv = InstanceFactory.create("BoolValue"); kv.name = "KillPart"; kv.attachRaw(kb)
        }

        z += 46
        part(course, "Landing2", size: Vector3(16, 2, 16), cf: .at(Vector3(0, 7, z)), color: stone, material: 816)
        let cp2 = spawn(course, at: Vector3(0, 8.5, z), color: green)
        cp2.name = "Checkpoint2"; cp2.set("Duration", .int(0), notify: false)

        z += 12
        let mover = part(course, "MovingPlatform", size: Vector3(8, 1, 8), cf: .at(Vector3(0, 7.5, z + 4)),
                         color: .fromRGB(13, 105, 172), material: 272)
        script(mover, "Move", source: TemplateScripts.move)

        z += 36
        part(course, "Landing3", size: Vector3(16, 2, 16), cf: .at(Vector3(0, 7, z)), color: stone, material: 816)
        let cp3 = spawn(course, at: Vector3(0, 8.5, z), color: green)
        cp3.name = "Checkpoint3"; cp3.set("Duration", .int(0), notify: false)

        z += 20
        let floor = part(course, "SpinFloor", size: Vector3(2, 30, 30),
                         cf: CFrame.at(Vector3(0, 7, z)) * .rz(.pi / 2), color: .fromRGB(163, 162, 165), material: 816)
        floor.set("shape", .enumValue(EnumValue(2)), notify: false)
        let spinner = part(course, "Spinner", size: Vector3(28, 1.2, 1.2), cf: .at(Vector3(0, 9, z)),
                           color: .fromRGB(255, 0, 0), material: 288)
        let killSpin = InstanceFactory.create("BoolValue"); killSpin.name = "KillPart"; killSpin.attachRaw(spinner)
        script(spinner, "Spin", source: TemplateScripts.spin)

        z += 22
        part(course, "Landing4", size: Vector3(16, 2, 16), cf: .at(Vector3(0, 7, z)), color: stone, material: 816)
        let cp4 = spawn(course, at: Vector3(0, 8.5, z), color: green)
        cp4.name = "Checkpoint4"; cp4.set("Duration", .int(0), notify: false)

        part(course, "Truss", size: Vector3(2, 24, 2), cf: .at(Vector3(0, 20, z + 7)),
             color: .fromRGB(163, 162, 165), material: 1088, cls: "TrussPart")
        let finish = part(course, "Finish", size: Vector3(16, 2, 16), cf: .at(Vector3(0, 31, z + 15)),
                          color: gold, material: 288)
        script(finish, "Win", source: TemplateScripts.win)

        script(dm.findService("ServerScriptService")!, "ObbyScript", source: TemplateScripts.obbyScript)
    }

    private static func arena(_ dm: DataModel, _ ws: Instance) {
        baseplate(ws)
        let teams = dm.findService("Teams")!
        for (name, num) in [("Red", Int32(21)), ("Blue", Int32(23))] {
            let t = InstanceFactory.create("Team")
            t.name = name
            t.set("TeamColor", .brickColor(BrickColorV(num)), notify: false)
            t.set("AutoAssignable", .bool(true), notify: false)
            t.attachRaw(teams)
        }
        let m = model(ws, "Arena")
        let wallColor = Color3.fromRGB(99, 95, 98)
        let s: Float = 160
        for (name, cf, size) in [
            ("NorthWall", CFrame.at(Vector3(0, 10, -s / 2)), Vector3(s, 20, 4)),
            ("SouthWall", CFrame.at(Vector3(0, 10, s / 2)), Vector3(s, 20, 4)),
            ("EastWall", CFrame.at(Vector3(s / 2, 10, 0)), Vector3(4, 20, s)),
            ("WestWall", CFrame.at(Vector3(-s / 2, 10, 0)), Vector3(4, 20, s)),
        ] {
            part(m, name, size: size, cf: cf, color: wallColor, material: 848)
        }
        var rng = JavaRandom(7)
        for _ in 0..<10 {
            let x = (rng.nextFloat() - 0.5) * (s - 40)
            let z = (rng.nextFloat() - 0.5) * (s - 60)
            let h = Float(rng.nextInt(3)) * 2 + 4
            for sign: Float in [1, -1] {
                part(m, "Cover", size: Vector3(6, h, 6), cf: .at(Vector3(x * sign, h / 2, z * sign)),
                     color: .fromRGB(124, 92, 70), material: 528)
            }
        }
        part(m, "CenterTower", size: Vector3(14, 10, 14), cf: .at(Vector3(0, 5, 0)),
             color: .fromRGB(163, 162, 165), material: 816)

        for (i, zPos) in [-s / 2 + 14, s / 2 - 14].enumerated() {
            let col = i == 0 ? Color3.fromRGB(196, 40, 28) : Color3.fromRGB(13, 105, 172)
            let sp = spawn(m, at: Vector3(0, 0.5, zPos), color: col)
            sp.name = i == 0 ? "RedSpawn" : "BlueSpawn"
            sp.set("Neutral", .bool(false), notify: false)
            sp.set("TeamColor", .brickColor(BrickColorV(i == 0 ? 21 : 23)), notify: false)
            sp.set("Duration", .int(3), notify: false)
        }

        let sword = InstanceFactory.create("Tool")
        sword.name = "Sword"
        sword.set("Grip", .cframe(CFrame.at(Vector3(0, -1.6, 0)) * .rx(-.pi / 2)), notify: false)
        sword.attachRaw(dm.findService("StarterPack")!)
        let handle = InstanceFactory.create("Part")
        handle.name = "Handle"
        handle.set("size", .vector3(Vector3(0.5, 4, 0.5)), notify: false)
        handle.set("Color3uint8", .color3(.fromRGB(163, 162, 165)), notify: false)
        handle.set("Material", .enumValue(EnumValue(1088)), notify: false)
        handle.set("CanCollide", .bool(false), notify: false)
        handle.set("Anchored", .bool(false), notify: false)
        handle.attachRaw(sword)
        script(sword, "SwordScript", source: TemplateScripts.swordScript)
        script(dm.findService("ServerScriptService")!, "Leaderboard", source: TemplateScripts.leaderboard)
    }

    private static func island(_ ws: Instance, _ cam: Instance) {
        let t = terrain(ws)
        let g = TerrainStore.of(t)
        TerrainGenerator.generate(g, .init(size: 512, seed: 20260412, biomes: [.water, .plains, .hills],
                                           biomeSize: 220, caves: false))
        TerrainOps.fillBall(g, center: Vector3(0, -40, 0), radius: 44, material: TerrainMaterials.fromName("Sand"))
        let hit = TerrainMesher.raycast(g, origin: Vector3(0, 400, 0), dir: Vector3(0, -1, 0), maxDist: 800)
        let y = ceil((hit.map { 400 - $0.t } ?? 4) / 4) * 4
        TerrainOps.fillCylinder(g, cframe: .at(Vector3(0, y + 40, 0)), height: 80, radius: 24, material: 0)
        TerrainOps.fillCylinder(g, cframe: .at(Vector3(0, y - 6, 0)), height: 12, radius: 22,
                                material: TerrainMaterials.fromName("Grass"))
        TerrainStore.flush(t)
        _ = spawn(ws, at: Vector3(0, 0.5 + y, 0))
        cam.set("CFrame", .cframe(.lookAt(Vector3(0, 70 + y, 140), Vector3(0, y, 0))), notify: false)
    }

    private static func village(_ ws: Instance) {
        flatTerrain(ws, size: 512)
        let t = terrain(ws)
        let g = TerrainStore.of(t)
        let cobble = TerrainMaterials.fromName("Cobblestone")
        TerrainOps.fillBlock(g, cframe: .at(Vector3(0, -1, 0)), size: Vector3(10, 2, 220), material: cobble)
        TerrainOps.fillBlock(g, cframe: .at(Vector3(0, -1, 0)), size: Vector3(220, 2, 10), material: cobble)
        TerrainStore.flush(t)

        let m = model(ws, "Village")
        var rng = JavaRandom(11)
        let walls: [Color3] = [.fromRGB(234, 184, 146), .fromRGB(204, 142, 105), .fromRGB(239, 184, 56), .fromRGB(248, 248, 248)]
        let roofs: [Color3] = [.fromRGB(124, 92, 70), .fromRGB(151, 0, 0), .fromRGB(91, 93, 105)]
        let plots = [(-1, -1), (-1, 1), (1, -1), (1, 1), (-1, -2), (1, 2), (2, -1), (-2, 1)]
        for (i, (gx, gz)) in plots.enumerated() {
            house(m, "House\(i)", at: Vector3(Float(gx) * 34, 0, Float(gz) * 34),
                  faceZ: gz > 0 ? -1 : 1, wall: walls[i % walls.count], roof: roofs[rng.nextInt(roofs.count)])
        }
        for _ in 0..<26 {
            let a = rng.nextFloat() * .pi * 2
            let r = rng.nextFloat() * 120 + 70
            tree(m, at: Vector3(cos(a) * r, 0, sin(a) * r), scale: rng.nextFloat() * 0.6 + 0.8)
        }

        let well = model(m, "Well")
        let base = part(well, "Base", size: Vector3(3, 8, 8), cf: CFrame.at(Vector3(0, 1.5, 0)) * .rz(.pi / 2),
                        color: .fromRGB(163, 162, 165), material: 880)
        base.set("shape", .enumValue(EnumValue(2)), notify: false)
        let water = part(well, "Water", size: Vector3(0.6, 6, 6), cf: CFrame.at(Vector3(0, 2.8, 0)) * .rz(.pi / 2),
                         color: .fromRGB(33, 84, 185), material: 272)
        water.set("shape", .enumValue(EnumValue(2)), notify: false)
        for px: Float in [-3.2, 3.2] {
            part(well, "Post", size: Vector3(0.6, 6, 0.6), cf: .at(Vector3(px, 6, 0)),
                 color: .fromRGB(105, 64, 40), material: 512)
        }
        part(well, "Roof", size: Vector3(8, 1.5, 5), cf: .at(Vector3(0, 9.5, 0)),
             color: .fromRGB(124, 92, 70), material: 528, cls: "WedgePart")

        _ = spawn(ws, at: Vector3(0, 0.5, 16))
    }

    private static func house(_ parent: Instance, _ name: String, at: Vector3, faceZ: Float, wall: Color3, roof: Color3) {
        let m = model(parent, name)
        func local(_ x: Float, _ y: Float, _ z: Float) -> CFrame {
            CFrame.at(Vector3(at.x + x, at.y + y, at.z + z * faceZ))
        }
        part(m, "Floor", size: Vector3(18, 1, 16), cf: local(0, 0.5, 0), color: .fromRGB(105, 64, 40), material: 528)
        part(m, "BackWall", size: Vector3(18, 10, 1), cf: local(0, 6, -7.5), color: wall, material: 848)
        part(m, "LeftWall", size: Vector3(1, 10, 16), cf: local(-8.5, 6, 0), color: wall, material: 848)
        part(m, "RightWall", size: Vector3(1, 10, 16), cf: local(8.5, 6, 0), color: wall, material: 848)
        part(m, "FrontLeft", size: Vector3(7, 10, 1), cf: local(-5.5, 6, 7.5), color: wall, material: 848)
        part(m, "FrontRight", size: Vector3(7, 10, 1), cf: local(5.5, 6, 7.5), color: wall, material: 848)
        part(m, "FrontTop", size: Vector3(4, 3, 1), cf: local(0, 9.5, 7.5), color: wall, material: 848)
        for wx: Float in [-5.5, 5.5] {
            let win = part(m, "Window", size: Vector3(3, 3, 1.1), cf: local(wx, 6, 7.5),
                           color: .fromRGB(128, 187, 219), material: 1568)
            win.set("Transparency", .float(0.4), notify: false)
        }
        let halfW: Float = 10
        for s: Float in [-1, 1] {
            part(m, "Roof", size: Vector3(18, 6, halfW),
                 cf: CFrame.at(Vector3(at.x + s * halfW / 2, at.y + 14, at.z)) * .ry(s < 0 ? .pi / 2 : -.pi / 2),
                 color: roof, material: 2308, cls: "WedgePart")
        }
        let lamp = part(m, "Lamp", size: Vector3(0.8, 0.8, 0.8), cf: local(3, 4, 8.6),
                        color: .fromRGB(255, 220, 150), material: 288)
        let light = InstanceFactory.create("PointLight")
        light.set("Range", .float(14), notify: false)
        light.set("Brightness", .float(1.2), notify: false)
        light.set("Color", .color3(.fromRGB(255, 214, 160)), notify: false)
        light.attachRaw(lamp)
    }

    private static func tree(_ parent: Instance, at: Vector3, scale s: Float) {
        let m = model(parent, "Tree")
        part(m, "Trunk", size: Vector3(1.6 * s, 8 * s, 1.6 * s), cf: .at(Vector3(at.x, 4 * s, at.z)),
             color: .fromRGB(105, 64, 40), material: 512)
        let leaves = part(m, "Leaves", size: Vector3(9 * s, 9 * s, 9 * s), cf: .at(Vector3(at.x, 10 * s, at.z)),
                          color: .fromRGB(75, 151, 75), material: 1284)
        leaves.set("shape", .enumValue(EnumValue(0)), notify: false)
    }

    // MARK: services & document loading

    @discardableResult
    static func service(_ dm: DataModel, _ cls: String) -> Instance {
        if let s = dm.findService(cls) { return s }
        let s = InstanceFactory.create(cls)
        s.isService = true
        s.attachRaw(dm)
        return s
    }

    public static func fromDocument(_ doc: RbxDocument) -> DataModel {
        let dm = DataModel()
        dm.meta.merge(doc.meta)
        for r in doc.roots {
            if ClassDb.isServiceName(r.className) { r.isService = true }
            r.attachRaw(dm)
        }
        for s in required { service(dm, s) }
        let ws = dm.findService("Workspace")!
        if ws.get("CurrentCamera")?.asInstance == nil {
            let cam = ws.findFirstChildOfClass("Camera") ?? {
                let c = InstanceFactory.create("Camera"); c.attachRaw(ws); return c
            }()
            ws.set("CurrentCamera", .ref(cam), notify: false)
        }
        ensureTerrain(ws)
        return dm
    }

    public static func ensureTerrain(_ ws: Instance) {
        if ws.findFirstChildOfClass("Terrain") != nil { return }
        let t = InstanceFactory.create("Terrain")
        t.name = "Terrain"
        t.set("Anchored", .bool(true), notify: false)
        t.set("Locked", .bool(true), notify: false)
        t.set("WaterColor", .color3(.fromRGB(12, 84, 92)), notify: false)
        t.set("WaterTransparency", .float(0.3), notify: false)
        t.set("WaterReflectance", .float(1), notify: false)
        t.set("WaterWaveSize", .float(0.15), notify: false)
        t.set("WaterWaveSpeed", .float(10), notify: false)
        t.isService = false
        t.attachRaw(ws)
    }
}
