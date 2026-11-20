import Foundation
import StudioCore

/// What a player's character should look like (port of engine/Avatar.kt's Spec).
public struct AvatarSpec {
    public var r15: Bool
    /// Body part name ("Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg") -> colour.
    public var bodyColors: [String: Color3]
    /// Instances (Shirt, Pants, ShirtGraphic, Accessory, face Decal) to clone onto the character.
    public var items: [Instance]
    public init(r15: Bool, bodyColors: [String: Color3], items: [Instance]) {
        self.r15 = r15; self.bodyColors = bodyColors; self.items = items
    }
}

extension CharacterBuilder {
    static func attachment(_ name: String, _ pos: Vector3, _ parent: Instance) {
        let a = InstanceFactory.create("Attachment")
        a.name = name
        a.set("CFrame", .cframe(.at(pos)), notify: false)
        a.attachRaw(parent)
    }

    /// Accessory attachment points on an R6 rig.
    static func addR6Attachments(_ m: Instance) {
        if let h = m.findFirstChild("Head") {
            attachment("HatAttachment", Vector3(0, 0.6, 0), h)
            attachment("HairAttachment", Vector3(0, 0.6, 0), h)
            attachment("FaceFrontAttachment", Vector3(0, 0, -0.6), h)
            attachment("FaceCenterAttachment", .zero, h)
        }
        if let t = m.findFirstChild("Torso") {
            attachment("NeckAttachment", Vector3(0, 1, 0), t)
            attachment("BodyFrontAttachment", Vector3(0, 0, -0.5), t)
            attachment("BodyBackAttachment", Vector3(0, 0, 0.5), t)
            attachment("LeftCollarAttachment", Vector3(-1, 1, 0), t)
            attachment("RightCollarAttachment", Vector3(1, 1, 0), t)
            attachment("WaistFrontAttachment", Vector3(0, -1, -0.5), t)
            attachment("WaistCenterAttachment", Vector3(0, -1, 0), t)
            attachment("WaistBackAttachment", Vector3(0, -1, 0.5), t)
        }
        if let a = m.findFirstChild("Left Arm") { attachment("LeftShoulderAttachment", Vector3(0, 1, 0), a); attachment("LeftGripAttachment", Vector3(0, -1, 0), a) }
        if let a = m.findFirstChild("Right Arm") { attachment("RightShoulderAttachment", Vector3(0, 1, 0), a); attachment("RightGripAttachment", Vector3(0, -1, 0), a) }
        if let l = m.findFirstChild("Left Leg") { attachment("LeftFootAttachment", Vector3(0, -1, 0), l) }
        if let l = m.findFirstChild("Right Leg") { attachment("RightFootAttachment", Vector3(0, -1, 0), l) }
    }

    /// Blocky R15 rig: same overall height as R6 (root 3 studs above the feet), standard part
    /// and joint names so Roblox R15 animations and scripts find them.
    public static func buildR15(name: String, at origin: CFrame = .at(Vector3(0, 3, 0))) -> Instance {
        let model = InstanceFactory.create("Model")
        model.name = name
        let skin = Color3.fromRGB(245, 205, 48), shirt = Color3.fromRGB(13, 105, 172), pants = Color3.fromRGB(39, 70, 45)
        // (name, size, centre relative to root, colour)
        let spec: [(String, Vector3, Vector3, Color3)] = [
            ("HumanoidRootPart", Vector3(2, 2, 1), .zero, skin),
            ("LowerTorso", Vector3(2, 0.4, 1), Vector3(0, -0.8, 0), shirt),
            ("UpperTorso", Vector3(2, 1.6, 1), Vector3(0, 0.2, 0), shirt),
            ("Head", Vector3(1.2, 1.2, 1.2), Vector3(0, 1.6, 0), skin),
            ("LeftUpperArm", Vector3(1, 1, 1), Vector3(-1.5, 0.5, 0), skin),
            ("LeftLowerArm", Vector3(1, 0.8, 1), Vector3(-1.5, -0.4, 0), skin),
            ("LeftHand", Vector3(1, 0.2, 1), Vector3(-1.5, -0.9, 0), skin),
            ("RightUpperArm", Vector3(1, 1, 1), Vector3(1.5, 0.5, 0), skin),
            ("RightLowerArm", Vector3(1, 0.8, 1), Vector3(1.5, -0.4, 0), skin),
            ("RightHand", Vector3(1, 0.2, 1), Vector3(1.5, -0.9, 0), skin),
            ("LeftUpperLeg", Vector3(1, 1, 1), Vector3(-0.5, -1.5, 0), pants),
            ("LeftLowerLeg", Vector3(1, 0.8, 1), Vector3(-0.5, -2.4, 0), pants),
            ("LeftFoot", Vector3(1, 0.2, 1), Vector3(-0.5, -2.9, 0), pants),
            ("RightUpperLeg", Vector3(1, 1, 1), Vector3(0.5, -1.5, 0), pants),
            ("RightLowerLeg", Vector3(1, 0.8, 1), Vector3(0.5, -2.4, 0), pants),
            ("RightFoot", Vector3(1, 0.2, 1), Vector3(0.5, -2.9, 0), pants),
        ]
        var parts: [String: Instance] = [:]
        var centres: [String: Vector3] = [:]
        for (n, size, c, col) in spec {
            let p = part(n, size, col)
            if n == "HumanoidRootPart" { p.set("Transparency", .float(1), notify: false) }
            PartData.setCFrame(p, origin * .at(c))
            p.attachRaw(model)
            parts[n] = p
            centres[n] = c
        }
        if let head = parts["Head"] {
            let face = InstanceFactory.create("Decal")
            face.name = "face"
            face.set("Texture", .string("rbxasset://textures/face.png"), notify: false)
            face.attachRaw(head)
        }
        // (joint, part0, part1, pivot relative to root): C0/C1 = pivot in each part's space.
        let joints: [(String, String, String, Vector3)] = [
            ("Root", "HumanoidRootPart", "LowerTorso", Vector3(0, -0.8, 0)),
            ("Waist", "LowerTorso", "UpperTorso", Vector3(0, -0.6, 0)),
            ("Neck", "UpperTorso", "Head", Vector3(0, 1.0, 0)),
            ("LeftShoulder", "UpperTorso", "LeftUpperArm", Vector3(-1.5, 0.8, 0)),
            ("LeftElbow", "LeftUpperArm", "LeftLowerArm", Vector3(-1.5, 0, 0)),
            ("LeftWrist", "LeftLowerArm", "LeftHand", Vector3(-1.5, -0.8, 0)),
            ("RightShoulder", "UpperTorso", "RightUpperArm", Vector3(1.5, 0.8, 0)),
            ("RightElbow", "RightUpperArm", "RightLowerArm", Vector3(1.5, 0, 0)),
            ("RightWrist", "RightLowerArm", "RightHand", Vector3(1.5, -0.8, 0)),
            ("LeftHip", "LowerTorso", "LeftUpperLeg", Vector3(-0.5, -1.0, 0)),
            ("LeftKnee", "LeftUpperLeg", "LeftLowerLeg", Vector3(-0.5, -2.0, 0)),
            ("LeftAnkle", "LeftLowerLeg", "LeftFoot", Vector3(-0.5, -2.8, 0)),
            ("RightHip", "LowerTorso", "RightUpperLeg", Vector3(0.5, -1.0, 0)),
            ("RightKnee", "RightUpperLeg", "RightLowerLeg", Vector3(0.5, -2.0, 0)),
            ("RightAnkle", "RightLowerLeg", "RightFoot", Vector3(0.5, -2.8, 0)),
        ]
        for (n, a, b, pivot) in joints {
            guard let p0 = parts[a], let p1 = parts[b] else { continue }
            let c0 = CFrame.at(pivot - centres[a]!), c1 = CFrame.at(pivot - centres[b]!)
            motor(n, p0, p1, c0, c1, parent: p1)
            attachment(n + "RigAttachment", pivot - centres[a]!, p0)
            attachment(n + "RigAttachment", pivot - centres[b]!, p1)
        }
        if let h = parts["Head"] {
            attachment("HatAttachment", Vector3(0, 0.6, 0), h)
            attachment("HairAttachment", Vector3(0, 0.6, 0), h)
            attachment("FaceFrontAttachment", Vector3(0, 0, -0.6), h)
            attachment("FaceCenterAttachment", .zero, h)
        }
        if let t = parts["UpperTorso"] {
            attachment("NeckAttachment", Vector3(0, 0.8, 0), t)
            attachment("BodyFrontAttachment", Vector3(0, 0, -0.5), t)
            attachment("BodyBackAttachment", Vector3(0, 0, 0.5), t)
            attachment("LeftCollarAttachment", Vector3(-1, 0.8, 0), t)
            attachment("RightCollarAttachment", Vector3(1, 0.8, 0), t)
        }
        if let t = parts["LowerTorso"] {
            attachment("WaistFrontAttachment", Vector3(0, 0, -0.5), t)
            attachment("WaistCenterAttachment", .zero, t)
            attachment("WaistBackAttachment", Vector3(0, 0, 0.5), t)
        }
        if let a = parts["LeftUpperArm"] { attachment("LeftShoulderAttachment", Vector3(0, 0.5, 0), a) }
        if let a = parts["RightUpperArm"] { attachment("RightShoulderAttachment", Vector3(0, 0.5, 0), a) }
        if let h = parts["RightHand"] { attachment("RightGripAttachment", Vector3(0, -0.1, 0), h) }
        if let h = parts["LeftHand"] { attachment("LeftGripAttachment", Vector3(0, -0.1, 0), h) }
        let hum = InstanceFactory.create("Humanoid")
        hum.set("RigType", .enumValue(EnumValue(1)), notify: false)
        hum.set("HipHeight", .float(2), notify: false)
        hum.attachRaw(model)
        InstanceFactory.create("Animator").attachRaw(hum)
        model.set("PrimaryPart", .ref(parts["HumanoidRootPart"]!), notify: false)
        return model
    }

    /// Body colour groups for both rigs.
    static func colorGroup(_ partName: String) -> String? {
        switch partName {
        case "Head": return "Head"
        case "Torso", "UpperTorso", "LowerTorso": return "Torso"
        case "Left Arm", "LeftUpperArm", "LeftLowerArm", "LeftHand": return "LeftArm"
        case "Right Arm", "RightUpperArm", "RightLowerArm", "RightHand": return "RightArm"
        case "Left Leg", "LeftUpperLeg", "LeftLowerLeg", "LeftFoot": return "LeftLeg"
        case "Right Leg", "RightUpperLeg", "RightLowerLeg", "RightFoot": return "RightLeg"
        default: return nil
        }
    }

    /// Dress a character with an avatar spec (Avatar.applyTo).
    public static func apply(_ spec: AvatarSpec, to ch: Instance) {
        for p in ch.children where p.isA("BasePart") {
            if let g = colorGroup(p.name), let c = spec.bodyColors[g] { PartData.setColor(p, c) }
        }
        for item in spec.items {
            let copy = item.cloneTree()
            if copy.className == "Decal", let head = ch.findFirstChild("Head") {
                head.findFirstChild("face")?.destroy()
                copy.name = "face"
                try? copy.setParent(head)
                continue
            }
            if ["Shirt", "Pants", "ShirtGraphic", "BodyColors"].contains(copy.className) {
                ch.findFirstChildOfClass(copy.className)?.destroy()
            }
            try? copy.setParent(ch)
            if copy.isA("Accoutrement") { attachAccessory(copy, to: ch) }
        }
    }
}
