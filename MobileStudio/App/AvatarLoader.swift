import Foundation
import StudioCore
import StudioScript

/// Loads the signed-in user's avatar for Play mode (port of engine/Avatar.kt fromUser):
/// avatar type, body colours, clothing, accessories and face from avatar.roblox.com.
enum AvatarLoader {
    private static var cached: (Int64, AvatarSpec)?

    static func load(userId: Int64) async -> AvatarSpec? {
        if let c = cached, c.0 == userId { return c.1 }
        guard let j = try? await RobloxWeb.json("https://avatar.roblox.com/v1/users/\(userId)/avatar") else { return nil }
        let r15 = (j["playerAvatarType"] as? String) == "R15"
        var colors: [String: Color3] = [:]
        if let bc = j["bodyColors"] as? [String: Any] {
            let keys = ["Head": "headColorId", "Torso": "torsoColorId", "LeftArm": "leftArmColorId", "RightArm": "rightArmColorId",
                        "LeftLeg": "leftLegColorId", "RightLeg": "rightLegColorId"]
            for (group, key) in keys {
                if let n = (bc[key] as? NSNumber)?.intValue { colors[group] = BrickColors.color(n) }
            }
        }
        var items: [Instance] = []
        let wanted: Set<String> = ["Shirt", "Pants", "TShirt", "Face", "Hat", "HairAccessory", "FaceAccessory", "NeckAccessory",
                                   "ShoulderAccessory", "FrontAccessory", "BackAccessory", "WaistAccessory"]
        for a in j["assets"] as? [[String: Any]] ?? [] {
            guard let id = (a["id"] as? NSNumber)?.int64Value,
                  let type = (a["assetType"] as? [String: Any])?["name"] as? String, wanted.contains(type) else { continue }
            guard let data = try? await AssetCache.shared.download(id), let doc = try? RbxFile.read(data) else { continue }
            for r in doc.roots {
                switch r.className {
                case "Shirt", "Pants", "ShirtGraphic", "Accessory", "Hat": items.append(r)
                case "Decal" where type == "Face": items.append(r)
                default:
                    if let inner = ([r] + r.descendants()).first(where: { ["Shirt", "Pants", "ShirtGraphic", "Accessory"].contains($0.className) }) {
                        items.append(inner)
                    }
                }
            }
        }
        let spec = AvatarSpec(r15: r15, bodyColors: colors, items: items)
        cached = (userId, spec)
        return spec
    }
}
