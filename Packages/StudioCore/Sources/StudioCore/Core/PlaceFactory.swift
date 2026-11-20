import Foundation

/// New-place templates and document -> DataModel conversion (port of core/PlaceFactory.kt).
public enum PlaceFactory {
    public enum Template: CaseIterable, Identifiable {
        case baseplate, classic, empty
        public var id: Self { self }
        public var title: String {
            switch self { case .baseplate: "Baseplate"; case .classic: "Classic Baseplate"; case .empty: "Empty Place" }
        }
        public var subtitle: String {
            switch self {
            case .baseplate: "A large grey baseplate and a spawn"
            case .classic: "The classic studded baseplate"
            case .empty: "Just a spawn location, no ground"
            }
        }
    }

    static let required = ["Workspace", "Players", "Lighting", "MaterialService", "ReplicatedFirst", "ReplicatedStorage",
                           "ServerScriptService", "ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "Teams",
                           "SoundService", "TextChatService"]

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

        if template != .empty {
            let bp = InstanceFactory.create("Part")
            bp.name = "Baseplate"
            bp.set("Anchored", .bool(true), notify: false)
            bp.set("Locked", .bool(true), notify: false)
            if template == .classic {
                bp.set("size", .vector3(Vector3(512, 20, 512)), notify: false)
                bp.set("CFrame", .cframe(.at(Vector3(0, -10, 0))), notify: false)
                bp.set("Color3uint8", .color3(.fromRGB(99, 95, 98)), notify: false)
                bp.set("TopSurface", .enumValue(EnumValue(3)), notify: false)
            } else {
                bp.set("size", .vector3(Vector3(2048, 16, 2048)), notify: false)
                bp.set("CFrame", .cframe(.at(Vector3(0, -8, 0))), notify: false)
                bp.set("Color3uint8", .color3(.fromRGB(91, 93, 105)), notify: false)
                let tex = InstanceFactory.create("Texture")
                tex.name = "Texture"
                tex.set("Texture", .string("rbxassetid://6372755229"), notify: false)
                tex.set("Face", .enumValue(EnumValue(1)), notify: false)
                tex.set("StudsPerTileU", .float(8), notify: false)
                tex.set("StudsPerTileV", .float(8), notify: false)
                tex.set("Transparency", .float(0.8), notify: false)
                tex.attachRaw(bp)
            }
            bp.attachRaw(ws)
        }

        let spawn = InstanceFactory.create("SpawnLocation")
        spawn.set("CFrame", .cframe(.at(Vector3(0, 0.5, 0))), notify: false)
        spawn.set("Color3uint8", .color3(.fromRGB(163, 162, 165)), notify: false)
        spawn.attachRaw(ws)

        let sp = dm.findService("StarterPlayer")!
        InstanceFactory.create("StarterPlayerScripts").attachRaw(sp)
        InstanceFactory.create("StarterCharacterScripts").attachRaw(sp)
        return dm
    }

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

    static func ensureTerrain(_ ws: Instance) {
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
