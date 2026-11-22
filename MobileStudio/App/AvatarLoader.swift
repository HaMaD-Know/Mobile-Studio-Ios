import Foundation
import StudioCore
import StudioScript

/// Loads and stores the playtest avatar choice (port of engine/Avatar.kt):
/// user's own Roblox avatar, another Roblox user's avatar, classic blocky avatar,
/// or a saved custom Model/Part character.
enum AvatarLoader {
    enum Mode: String, CaseIterable {
        case account, user, classic, character
    }

    private static var cached: [Int64: AvatarSpec] = [:]
    private static let d = UserDefaults.standard

    static var mode: Mode {
        get {
            if let raw = d.string(forKey: "avatar.mode"), let m = Mode(rawValue: raw) { return m }
            let useMy = d.object(forKey: "useMyAvatar") as? Bool ?? true
            return useMy ? .account : .classic
        }
        set {
            d.set(newValue.rawValue, forKey: "avatar.mode")
            d.set(newValue == .account, forKey: "useMyAvatar")
        }
    }

    static var otherUserId: Int64 {
        get { (d.object(forKey: "avatar.otherId") as? NSNumber)?.int64Value ?? 0 }
        set { d.set(newValue, forKey: "avatar.otherId") }
    }

    static var otherUserName: String {
        get { d.string(forKey: "avatar.otherName") ?? "" }
        set { d.set(newValue, forKey: "avatar.otherName") }
    }

    static var characterName: String {
        get { d.string(forKey: "avatar.charName") ?? "" }
        set { d.set(newValue, forKey: "avatar.charName") }
    }

    private static var characterFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MobileStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("custom_character.rbxm")
    }

    static var hasCharacter: Bool {
        FileManager.default.fileExists(atPath: characterFile.path)
    }

    static func saveCharacter(data: Data, name: String) throws {
        try data.write(to: characterFile, options: .atomic)
        characterName = name
        mode = .character
    }

    static func loadCharacter() -> Instance? {
        guard let data = try? Data(contentsOf: characterFile),
              let doc = try? RbxFile.read(data) else { return nil }
        return doc.roots.first
    }

    static func clearCharacter() {
        try? FileManager.default.removeItem(at: characterFile)
        characterName = ""
        if mode == .character { mode = .account }
    }

    /// The Roblox userId whose avatar is currently selected (for Playtest and Rig Builder), if any.
    static var activeUserId: Int64? {
        switch mode {
        case .account: return AccountStore.shared.userId
        case .user: return otherUserId != 0 ? otherUserId : nil
        case .classic, .character: return nil
        }
    }

    /// Display label for the currently selected Roblox avatar (e.g. "@Player").
    static var activeAvatarLabel: String? {
        switch mode {
        case .account:
            guard AccountStore.shared.userId != nil else { return nil }
            let n = AccountStore.shared.userName ?? "My Avatar"
            return n.hasPrefix("@") ? n : "@\(n)"
        case .user:
            guard otherUserId != 0, !otherUserName.isEmpty else { return nil }
            return "@\(otherUserName)"
        case .classic, .character:
            return nil
        }
    }

    static func load(userId: Int64) async -> AvatarSpec? {
        if let c = cached[userId] { return c }
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
        cached[userId] = spec
        return spec
    }
}
