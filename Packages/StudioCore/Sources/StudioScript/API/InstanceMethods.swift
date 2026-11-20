import Foundation
import Luau
import StudioCore

/// BasePart / Model / WorldRoot / Camera methods.
enum PhysicalAPI {
    static func worldParts(_ rt: ScriptRuntime, _ root: Instance) -> [Instance] {
        root.descendants().filter { $0.isA("BasePart") && $0.className != "Terrain" }
    }

    static func pushHit(_ c: LuaCall, _ h: Geometry.Hit?) {
        guard let h else { c.pushNil(); return }
        c.push(.raycastResult(RaycastResultV(instance: h.part, position: h.point, normal: h.normal,
                                             distance: (h.point - h.point).magnitude + h.t, material: PartData.material(h.part))))
    }

    static func call(_ c: LuaCall, _ inst: Instance, _ m: String, _ api: InstanceAPI) throws -> Int32? {
        let rt = c.rt
        if inst.isA("WorldRoot") {
            switch m {
            case "Raycast":
                let o = try c.checkVector3(2, m), d = try c.checkVector3(3, m)
                var params: RaycastParamsV?
                if case .raycastParams(let p)? = c.object(4) { params = p }
                if let host = rt.host, let r = host.raycast(origin: o, direction: d, params: params) {
                    c.push(.raycastResult(r)); return 1
                }
                if rt.host != nil { c.pushNil(); return 1 }
                let hit = Geometry.raycast(worldParts(rt, inst), origin: o, direction: d) { p in
                    p.get("CanQuery")?.asBool != false && (params?.accepts(p) ?? true) &&
                        (params?.respectCanCollide != true || p.get("CanCollide")?.asBool != false)
                }
                if let hit {
                    c.push(.raycastResult(RaycastResultV(instance: hit.part, position: hit.point, normal: hit.normal,
                                                         distance: d.magnitude * hit.t, material: PartData.material(hit.part))))
                } else { c.pushNil() }
                return 1
            case "Blockcast", "Spherecast", "Shapecast":
                // Approximated by a ray from the shape centre.
                let o: Vector3 = m == "Blockcast" ? (try c.checkCFrame(2, m)).position : (m == "Spherecast" ? try c.checkVector3(2, m) : PartData.cframe(try c.checkInstance(2, m)).position)
                let d = try c.checkVector3(m == "Shapecast" ? 3 : (m == "Blockcast" ? 4 : 4), m)
                var params: RaycastParamsV?
                if case .raycastParams(let p)? = c.object(m == "Shapecast" ? 4 : 5) { params = p }
                if let r = rt.host?.raycast(origin: o, direction: d, params: params) { c.push(.raycastResult(r)) } else { c.pushNil() }
                return 1
            case "GetPartBoundsInBox", "GetPartBoundsInRadius", "GetPartsInPart":
                var params: OverlapParamsV?
                if case .overlapParams(let p)? = c.object(m == "GetPartsInPart" ? 3 : 4) { params = p }
                let accept: (Instance) -> Bool = { p in p.get("CanQuery")?.asBool != false && (params?.accepts(p) ?? true) }
                var found: [Instance]
                switch m {
                case "GetPartBoundsInBox": found = Geometry.partsInBox(worldParts(rt, inst), try c.checkCFrame(2, m), try c.checkVector3(3, m), accept: accept)
                case "GetPartBoundsInRadius": found = Geometry.partsInRadius(worldParts(rt, inst), try c.checkVector3(2, m), try c.checkFloat(3, m), accept: accept)
                default:
                    let part = try c.checkInstance(2, m)
                    found = Geometry.partsInBox(worldParts(rt, inst), PartData.cframe(part), PartData.size(part)) { $0 !== part && accept($0) }
                }
                if let mx = params?.maxParts, mx > 0 { found = Array(found.prefix(mx)) }
                c.pushArray(found) { c.push($0) }; return 1
            case "FindPartOnRay", "FindPartOnRayWithIgnoreList", "FindPartOnRayWithWhitelist":
                guard case .ray(let ray)? = c.object(2) else { throw c.argError(2, "Ray", m) }
                var list: [Instance] = []
                if m == "FindPartOnRay" { if let i = c.instance(3) { list = [i] } } else { list = try DataTypes.instances(c, 3) }
                let white = m == "FindPartOnRayWithWhitelist"
                let hit = Geometry.raycast(worldParts(rt, inst), origin: ray.origin, direction: ray.direction) { p in
                    let inList = list.contains { p === $0 || p.isDescendant(of: $0) }
                    return white ? inList : !inList
                }
                c.push(hit?.part); c.push(hit?.point ?? ray.origin + ray.direction); c.push(hit?.normal ?? .zero)
                c.push(.enumItem(ScriptEnums.item("Material", value: hit.map { PartData.material($0.part) } ?? 1792)!))
                return 4
            case "FindPartsInRegion3", "FindPartsInRegion3WithIgnoreList", "FindPartsInRegion3WithWhiteList", "IsRegion3Empty", "IsRegion3EmptyWithIgnoreList":
                guard case .region3(let r)? = c.object(2) else { throw c.argError(2, "Region3", m) }
                var list: [Instance] = []
                if m.hasSuffix("List") { list = try DataTypes.instances(c, 3) } else if let i = c.instance(3) { list = [i] }
                let white = m.hasSuffix("WhiteList")
                var found = Geometry.partsInBox(worldParts(rt, inst), .at((r.min + r.max) * 0.5), r.max - r.min) { p in
                    let inList = list.contains { p === $0 || p.isDescendant(of: $0) }
                    return white ? inList : !inList
                }
                if m.hasPrefix("IsRegion3Empty") { c.push(found.isEmpty); return 1 }
                let mx = Int(c.optNumber(4, 20))
                found = Array(found.prefix(mx))
                c.pushArray(found) { c.push($0) }; return 1
            case "ArePartsTouchingOthers":
                let ps = try DataTypes.instances(c, 2)
                let all = worldParts(rt, inst)
                c.push(ps.contains { p in !Geometry.partsInBox(all, PartData.cframe(p), PartData.size(p) + Vector3(0.05, 0.05, 0.05)) { q in q !== p && !ps.contains { $0 === q } }.isEmpty })
                return 1
            case "BulkMoveTo":
                let ps = try DataTypes.instances(c, 2)
                guard c.isTable(3) else { throw c.argError(3, "table", m) }
                for (k, p) in ps.enumerated() {
                    lua_rawgeti(c.L, 3, Int32(k + 1))
                    if let cf = c.cframe(-1) { PartData.setCFrame(p, cf) }
                    lua_settop(c.L, -2)
                }
                return 0
            case "GetServerTimeNow": c.push(Date().timeIntervalSince1970); return 1
            case "GetRealPhysicsFPS": c.push(60); return 1
            case "GetNumAwakeParts": c.push(0); return 1
            case "GetPhysicsThrottling": c.push(100); return 1
            case "JoinToOutsiders", "UnjoinFromOutsiders", "ZoomToExtents": return 0
            default: break
            }
        }
        if inst.isA("BasePart") {
            switch m {
            case "GetMass": c.push(Physics.mass(inst)); return 1
            case "GetRootPart": c.push(inst); return 1
            case "GetConnectedParts", "GetJoints":
                let joints = rt.dm.descendants().filter { j in
                    (j.isA("JointInstance") || j.className == "WeldConstraint") &&
                        [j.get("Part0")?.asInstance, j.get("Part1")?.asInstance, j.get("Part0Internal")?.asInstance, j.get("Part1Internal")?.asInstance]
                        .contains { $0 === inst }
                }
                if m == "GetJoints" { c.pushArray(joints) { c.push($0) }; return 1 }
                var parts: [Instance] = [inst]
                for j in joints {
                    for p in [j.get("Part0")?.asInstance, j.get("Part1")?.asInstance, j.get("Part0Internal")?.asInstance, j.get("Part1Internal")?.asInstance] {
                        if let p, !parts.contains(where: { $0 === p }) { parts.append(p) }
                    }
                }
                c.pushArray(parts) { c.push($0) }; return 1
            case "GetTouchingParts": c.pushArray(rt.host?.touchingParts(inst) ?? []) { c.push($0) }; return 1
            case "ApplyImpulse", "ApplyImpulseAtPosition":
                let imp = try c.checkVector3(2, m)
                rt.host?.applyImpulse(inst, imp); return 0
            case "ApplyAngularImpulse": return 0
            case "GetVelocityAtPosition": c.push(rt.host?.velocity(of: inst) ?? .zero); return 1
            case "Resize":
                let face = c.enumItem(2)?.value ?? 0, delta = try c.checkFloat(3, m)
                let axis = face % 3, sign: Float = face < 3 ? 1 : -1
                var s = PartData.size(inst)
                guard s[axis] + delta > 0 else { c.push(false); return 1 }
                s[axis] += delta
                let cf = PartData.cframe(inst)
                PartData.setSize(inst, s)
                PartData.setCFrame(inst, cf + cf.vectorToWorld(Vector3.axis(axis)) * (delta * 0.5 * sign))
                c.push(true); return 1
            case "CanCollideWith":
                let o = try c.checkInstance(2, m)
                c.push(Physics.collidable(inst.get("CollisionGroup")?.asString ?? "Default", o.get("CollisionGroup")?.asString ?? "Default"))
                return 1
            case "SetNetworkOwner", "SetNetworkOwnershipAuto", "MakeJoints": return 0
            case "GetNetworkOwner": c.pushNil(); return 1
            case "CanSetNetworkOwnership": c.push(true); c.pushNil(); return 2
            case "IsGrounded": c.push(inst.get("Anchored")?.asBool == true); return 1
            case "BreakJoints":
                for j in rt.dm.descendants() where (j.isA("JointInstance") || j.className == "WeldConstraint") &&
                    [j.get("Part0")?.asInstance, j.get("Part1")?.asInstance].contains(where: { $0 === inst }) { j.destroy() }
                return 0
            case "GetPivot": c.push(ModelMath.pivot(inst)); return 1
            case "PivotTo": ModelMath.pivotTo(inst, try c.checkCFrame(2, m)); return 0
            case "SubtractAsync", "UnionAsync", "IntersectAsync": throw LuaError("\(m) (solid modeling) is not available in scripts on this device")
            case "GetClosestPointOnSurface":
                let p = try c.checkVector3(2, m)
                let cf = PartData.cframe(inst), h = PartData.size(inst) * 0.5, l = cf.pointToObject(p)
                c.push(cf.pointToWorld(Vector3(max(-h.x, min(h.x, l.x)), max(-h.y, min(h.y, l.y)), max(-h.z, min(h.z, l.z))))); return 1
            case "AngularAccelerationToTorque", "TorqueToAngularAcceleration": c.push(c.vector3(2) ?? .zero); return 1
            default: break
            }
        }
        if inst.isA("Model") {
            switch m {
            case "GetPivot", "GetModelCFrame": c.push(m == "GetPivot" ? ModelMath.pivot(inst) : ModelMath.boundingBox(inst).0); return 1
            case "PivotTo": ModelMath.pivotTo(inst, try c.checkCFrame(2, m)); return 0
            case "MoveTo":
                let target = try c.checkVector3(2, m)
                let (bb, size) = ModelMath.boundingBox(inst)
                // Raise until it doesn't overlap anything (Roblox MoveTo behaviour), up to 200 studs.
                var pos = target
                let mine = Set(ModelMath.parts(inst).map(ObjectIdentifier.init))
                let others = worldParts(rt, rt.dm.workspace).filter { !mine.contains(ObjectIdentifier($0)) && $0.get("CanCollide")?.asBool != false }
                for _ in 0..<200 {
                    if Geometry.partsInBox(others, .at(pos), size * 0.98, accept: { _ in true }).isEmpty { break }
                    pos.y += 1
                }
                let pivotOffset = bb.position - ModelMath.pivot(inst).position
                ModelMath.pivotTo(inst, ModelMath.pivot(inst).withPosition(pos - pivotOffset))
                return 0
            case "GetBoundingBox": let (cf, s) = ModelMath.boundingBox(inst); c.push(cf); c.push(s); return 2
            case "GetExtentsSize", "GetModelSize": c.push(ModelMath.boundingBox(inst).1); return 1
            case "SetPrimaryPartCFrame":
                guard let pp = inst.get("PrimaryPart")?.asInstance else { throw LuaError("Model:SetPrimaryPartCFrame() failed because no PrimaryPart has been set, or the PrimaryPart no longer exists. Please set Model.PrimaryPart before using this.") }
                let delta = (try c.checkCFrame(2, m)) * PartData.cframe(pp).inverse
                for p in ModelMath.parts(inst) { PartData.setCFrame(p, delta * PartData.cframe(p)) }
                return 0
            case "GetPrimaryPartCFrame":
                guard let pp = inst.get("PrimaryPart")?.asInstance else { c.pushNil(); return 1 }
                c.push(PartData.cframe(pp)); return 1
            case "TranslateBy":
                let d = try c.checkVector3(2, m)
                for p in ModelMath.parts(inst) { PartData.setCFrame(p, PartData.cframe(p) + d) }
                return 0
            case "ScaleTo":
                let target = try c.checkFloat(2, m)
                let cur = Float(inst.attributes["__scale"]?.asFloat ?? 1)
                let k = target / cur
                let piv = ModelMath.pivot(inst)
                for p in ModelMath.parts(inst) {
                    let local = piv.pointToObject(PartData.cframe(p).position)
                    PartData.setSize(p, PartData.size(p) * k)
                    PartData.setCFrame(p, PartData.cframe(p).withPosition(piv.pointToWorld(local * k)))
                }
                inst.attributes["__scale"] = .double(Double(target))
                return 0
            case "GetScale": c.push(Double(inst.attributes["__scale"]?.asFloat ?? 1)); return 1
            case "BreakJoints":
                for j in inst.descendants() where j.isA("JointInstance") || j.className == "WeldConstraint" { j.destroy() }
                return 0
            case "MakeJoints", "ResetOrientationToIdentity", "AddPersistentPlayer", "RemovePersistentPlayer": return 0
            default: break
            }
        }
        if inst.className == "Camera" {
            switch m {
            case "ScreenPointToRay", "ViewportPointToRay":
                let r = rt.host?.cameraRay(x: try c.checkFloat(2, m), y: try c.checkFloat(3, m)) ?? Ray(PartData.cframe(inst).position, PartData.cframe(inst).lookVector)
                c.push(.ray(Ray(r.origin + r.direction.unit * c.optFloat(4, 0), r.direction.unit))); return 1
            case "WorldToViewportPoint", "WorldToScreenPoint":
                let (v, on) = rt.host?.worldToViewport(try c.checkVector3(2, m)) ?? (Vector3.zero, false)
                c.push(v); c.push(on); return 2
            case "GetPartsObscuringTarget": lua_createtable(c.L, 0, 0); return 1
            case "Interpolate":
                inst.set("CFrame", .cframe(try c.checkCFrame(2, m))); inst.set("Focus", .cframe(try c.checkCFrame(3, m))); return 0
            case "ZoomToExtents": return 0
            case "GetRenderCFrame": c.push(inst.get("CFrame")?.asCFrame ?? .identity); return 1
            case "GetRoll": c.push(0); return 1
            case "SetRoll": return 0
            default: break
            }
        }
        return nil
    }
}

/// Humanoid / Animator / Player / Tool methods.
enum HumanoidAPI {
    static func call(_ c: LuaCall, _ inst: Instance, _ m: String, _ api: InstanceAPI) throws -> Int32? {
        let rt = c.rt
        switch (inst.className, m) {
        case ("Humanoid", "TakeDamage"):
            let char = inst.parent
            if char?.findFirstChildOfClass("ForceField") != nil { return 0 }
            let h = (inst.get("Health_XML")?.asFloat ?? 100) - (try c.checkFloat(2, m))
            try api.setValue(inst, "Health", .number(Double(max(0, h))))
            return 0
        case ("Humanoid", "Move"):
            var d = try c.checkVector3(2, m)
            if c.bool(3), let cam = rt.dm.workspace.get("CurrentCamera")?.asInstance?.get("CFrame")?.asCFrame {
                let fwd = Vector3(cam.lookVector.x, 0, cam.lookVector.z).unit, right = Vector3(cam.rightVector.x, 0, cam.rightVector.z).unit
                d = right * d.x - fwd * d.z
            }
            rt.host?.humanoidMove(inst, direction: d); return 0
        case ("Humanoid", "MoveTo"):
            var target = try c.checkVector3(2, m)
            if let part = c.instance(3) { target = PartData.cframe(part).pointToWorld(target) }
            inst.set("WalkToPoint", .vector3(target), notify: false)
            rt.host?.humanoidMoveTo(inst, target: target); return 0
        case ("Humanoid", "ChangeState"):
            let s = c.enumItem(2)?.value ?? Int(c.number(2) ?? 8)
            if s == 3 { rt.host?.humanoidJump(inst) }
            if s == 15 { try api.setValue(inst, "Health", .number(0)) }
            inst.set("__State", .int(Int32(s)), notify: false)
            rt.fire(inst, "StateChanged", [.object(.enumItem(ScriptEnums.item("HumanoidStateType", value: 8)!)),
                                           .object(.enumItem(ScriptEnums.item("HumanoidStateType", value: s) ?? ScriptEnums.item("HumanoidStateType", value: 8)!))])
            return 0
        case ("Humanoid", "GetState"):
            let stored: Int32? = inst.get("__State").flatMap { v -> Int32? in if case .int(let x) = v { return x }; return nil }
            let s = Int(stored ?? 8)
            c.push(.enumItem(ScriptEnums.item("HumanoidStateType", value: s) ?? ScriptEnums.item("HumanoidStateType", value: 8)!)); return 1
        case ("Humanoid", "SetStateEnabled"):
            let s = c.enumItem(2)?.name ?? ""
            inst.attributes["__state_" + s] = .bool(c.bool(3)); return 0
        case ("Humanoid", "GetStateEnabled"):
            c.push(inst.attributes["__state_" + (c.enumItem(2)?.name ?? "")]?.asBool ?? true); return 1
        case ("Humanoid", "LoadAnimation"), ("Animator", "LoadAnimation"), ("AnimationController", "LoadAnimation"):
            let anim = try c.checkInstance(2, m)
            let owner = inst.className == "Animator" ? (inst.parent ?? inst) : inst
            guard let t = rt.host?.loadTrack(owner: owner, animation: anim) else {
                c.push(.track(AnimTrackRef(owner: owner, animation: anim))); return 1
            }
            c.push(.track(t)); return 1
        case ("Humanoid", "GetPlayingAnimationTracks"), ("Animator", "GetPlayingAnimationTracks"), ("AnimationController", "GetPlayingAnimationTracks"):
            let owner = inst.className == "Animator" ? (inst.parent ?? inst) : inst
            c.pushArray(rt.host?.playingTracks(owner) ?? []) { c.push(.track($0)) }; return 1
        case ("Animator", "StepAnimations"): return 0
        case ("Humanoid", "EquipTool"): rt.host?.equipTool(inst, try c.checkInstance(2, m)); return 0
        case ("Humanoid", "UnequipTools"): rt.host?.unequipTools(inst); return 0
        case ("Humanoid", "AddAccessory"):
            let acc = try c.checkInstance(2, m)
            guard let ch = inst.parent else { return 0 }
            try? acc.setParent(ch)
            CharacterBuilder.attachAccessory(acc, to: ch)
            return 0
        case ("Humanoid", "GetAccessories"):
            c.pushArray(inst.parent?.children.filter { $0.isA("Accoutrement") } ?? []) { c.push($0) }; return 1
        case ("Humanoid", "RemoveAccessories"):
            for a in inst.parent?.children.filter({ $0.isA("Accoutrement") }) ?? [] { a.destroy() }
            return 0
        case ("Humanoid", "ApplyDescription"), ("Humanoid", "BuildRigFromAttachments"), ("Humanoid", "ReplaceBodyPartR15"): return 0
        case ("Humanoid", "GetAppliedDescription"): c.push(InstanceFactory.create("HumanoidDescription")); return 1
        case ("Humanoid", "GetLimb"):
            let p = try c.checkInstance(2, m)
            let limbs = ["Head": 0, "Torso": 1, "Left Arm": 2, "Right Arm": 3, "Left Leg": 4, "Right Leg": 5]
            c.push(.enumItem(ScriptEnums.item("Limb", value: limbs[p.name] ?? 6) ?? EnumItem(enumType: "Limb", name: "Unknown", value: 6))); return 1
        case ("Humanoid", "GetBodyPartR15"):
            c.push(.enumItem(EnumItem(enumType: "BodyPartR15", name: "Unknown", value: 17))); return 1
        case ("Humanoid", "GetMoveVelocity"):
            c.push((rt.host?.moveDirection(inst) ?? .zero) * (inst.get("WalkSpeed")?.asFloat ?? 16)); return 1

        case ("Player", "LoadCharacter"), ("Player", "LoadCharacterAsync"): rt.host?.respawn(inst); return 0
        case ("Player", "Kick"):
            rt.log(.error, "You were kicked from this experience: \(c.optString(2) ?? "")")
            return 0
        case ("Player", "GetMouse"):
            if let mouse = inst.findFirstChildOfClass("PlayerMouse") { c.push(mouse); return 1 }
            let mouse = Instance("PlayerMouse")
            mouse.name = "Mouse"
            mouse.archivable = false
            mouse.attachRaw(inst)
            c.push(mouse); return 1
        case ("Player", "IsInGroup"), ("Player", "IsFriendsWith"): c.push(false); return 1
        case ("Player", "GetRankInGroup"): c.push(0); return 1
        case ("Player", "GetRoleInGroup"): c.push("Guest"); return 1
        case ("Player", "HasAppearanceLoaded"): c.push(true); return 1
        case ("Player", "GetNetworkPing"): c.push(0); return 1
        case ("Player", "DistanceFromCharacter"):
            let p = try c.checkVector3(2, m)
            guard let ch = inst.get("Character")?.asInstance, let head = ch.findFirstChild("Head") ?? ch.findFirstChild("HumanoidRootPart") else { c.push(0); return 1 }
            c.push((PartData.cframe(head).position - p).magnitude); return 1
        case ("Player", "GetFriendsOnline"), ("Player", "GetJoinData"): lua_createtable(c.L, 0, 0); return 1
        case ("Player", "ClearCharacterAppearance"), ("Player", "RequestStreamAroundAsync"): return 0

        case ("Tool", "Activate"): rt.fire(inst, "Activated"); return 0
        case ("Tool", "Deactivate"): rt.fire(inst, "Deactivated"); return 0
        default: return nil
        }
    }
}

/// Sounds, bindables, remotes, GUI tweens, prompts...
enum MiscAPI {
    static func call(_ c: LuaCall, _ inst: Instance, _ m: String, _ api: InstanceAPI) throws -> Int32? {
        let rt = c.rt
        func args(from i: Int32) -> [ScriptValue] {
            guard c.top >= i else { return [] }
            return (i...c.top).map { rt.readValue(c.L, $0) }
        }
        func localPlayer() -> ScriptValue {
            rt.dm.findService("Players")?.children.first { $0.className == "Player" }.map { .object(.instance($0)) } ?? .nil_
        }
        switch (inst.className, m) {
        case ("Sound", "Play"), ("Sound", "Resume"):
            inst.set("Playing", .bool(true))
            if m == "Play" { inst.set("TimePosition", .double(0)) }
            rt.host?.playSound(inst)
            rt.fire(inst, m == "Play" ? "Played" : "Resumed", [.string(inst.get("SoundId")?.description ?? "")])
            return 0
        case ("Sound", "Stop"), ("Sound", "Pause"):
            inst.set("Playing", .bool(false))
            rt.host?.stopSound(inst)
            rt.fire(inst, m == "Stop" ? "Stopped" : "Paused", [.string(inst.get("SoundId")?.description ?? "")])
            return 0
        case ("BindableEvent", "Fire"):
            rt.fire(inst, "Event", args(from: 2)); return 0
        case ("BindableFunction", "Invoke"):
            return try invoke(c, inst, "OnInvoke", args(from: 2))
        case ("RemoteEvent", "FireServer"), ("UnreliableRemoteEvent", "FireServer"):
            rt.fire(inst, "OnServerEvent", [localPlayer()] + args(from: 2)); return 0
        case ("RemoteEvent", "FireClient"), ("UnreliableRemoteEvent", "FireClient"):
            rt.fire(inst, "OnClientEvent", args(from: 3)); return 0
        case ("RemoteEvent", "FireAllClients"), ("UnreliableRemoteEvent", "FireAllClients"):
            rt.fire(inst, "OnClientEvent", args(from: 2)); return 0
        case ("RemoteFunction", "InvokeServer"):
            return try invoke(c, inst, "OnServerInvoke", [localPlayer()] + args(from: 2))
        case ("RemoteFunction", "InvokeClient"):
            return try invoke(c, inst, "OnClientInvoke", args(from: 3))
        case ("TextBox", "CaptureFocus"): inst.attributes["__focused"] = .bool(true); rt.fire(inst, "Focused"); return 0
        case ("TextBox", "ReleaseFocus"):
            inst.attributes["__focused"] = nil
            rt.fire(inst, "FocusLost", [.bool(c.bool(2)), .nil_]); return 0
        case ("TextBox", "IsFocused"): c.push(inst.attributes["__focused"] != nil); return 1
        case ("ParticleEmitter", "Emit"), ("ParticleEmitter", "Clear"), ("Trail", "Clear"), ("Beam", "SetTextureOffset"): return 0
        case ("ProximityPrompt", "InputHoldBegin"):
            rt.fire(inst, "Triggered", [localPlayer()])
            if let svc = rt.dm.findService("ProximityPromptService") { rt.fire(svc, "PromptTriggered", [.object(.instance(inst)), localPlayer()]) }
            return 0
        case ("ProximityPrompt", "InputHoldEnd"): rt.fire(inst, "TriggerEnded", [localPlayer()]); return 0
        default: break
        }
        if inst.isA("GuiObject") && (m == "TweenPosition" || m == "TweenSize" || m == "TweenSizeAndPosition") {
            var goals: [String: ScriptValue] = [:]
            var i: Int32 = 2
            if m != "TweenSize" { if let u = c.udim2(i) { goals[m == "TweenSizeAndPosition" ? "Size" : "Position"] = .object(.udim2(u)) }; i += 1 }
            if m == "TweenSizeAndPosition" { if let u = c.udim2(i) { goals["Position"] = .object(.udim2(u)) }; i += 1 }
            if m == "TweenSize" { if let u = c.udim2(i) { goals["Size"] = .object(.udim2(u)) }; i += 1 }
            var info = TweenInfoV()
            info.direction = c.enumItem(i)?.value ?? 1
            info.style = c.enumItem(i + 1)?.value ?? 3
            info.time = c.optFloat(i + 2, 1)
            let tw = Tween(inst: inst, info: info, goals: goals)
            if c.isFunction(i + 4) { _ = rt.connect(tw, "Completed", c.ref(i + 4), once: true) }
            rt.playTween(tw)
            c.push(true); return 1
        }
        return nil
    }

    /// BindableFunction / RemoteFunction invocation through the callback property.
    private static func invoke(_ c: LuaCall, _ inst: Instance, _ cb: String, _ args: [ScriptValue]) throws -> Int32 {
        if let fn = c.rt.callbacks[ObjectIdentifier(inst)]?[cb] {
            return try c.rt.callLua(c, fn, args)
        }
        throw LuaError("\(cb) is not set on \(inst.fullName())")
    }
}

/// Builds characters (port of PlaySession.buildR6 / buildJoints).
public enum CharacterBuilder {
    static func part(_ name: String, _ size: Vector3, _ color: Color3) -> Instance {
        let p = InstanceFactory.create("Part")
        p.name = name
        p.set("size", .vector3(size), notify: false)
        p.set("Color3uint8", .color3(color), notify: false)
        p.set("CanCollide", .bool(false), notify: false)
        p.set("Anchored", .bool(false), notify: false)
        return p
    }

    static func motor(_ name: String, _ p0: Instance, _ p1: Instance, _ c0: CFrame, _ c1: CFrame, parent: Instance) {
        let m = InstanceFactory.create("Motor6D")
        m.name = name
        m.set("Part0", .ref(p0), notify: false)
        m.set("Part1", .ref(p1), notify: false)
        m.set("C0", .cframe(c0), notify: false)
        m.set("C1", .cframe(c1), notify: false)
        m.attachRaw(parent)
    }

    /// Classic blocky R6 rig: HumanoidRootPart + Torso, Head, arms, legs, Motor6D joints and a Humanoid.
    public static func buildR6(name: String, at origin: CFrame = .at(Vector3(0, 3, 0))) -> Instance {
        let model = InstanceFactory.create("Model")
        model.name = name
        let skin = Color3.fromRGB(245, 205, 48), shirt = Color3.fromRGB(13, 105, 172), pants = Color3.fromRGB(39, 70, 45)
        let root = part("HumanoidRootPart", Vector3(2, 2, 1), skin)
        root.set("Transparency", .float(1), notify: false)
        let torso = part("Torso", Vector3(2, 2, 1), shirt)
        let head = part("Head", Vector3(2, 1, 1), skin)
        let mesh = InstanceFactory.create("SpecialMesh")
        mesh.set("MeshType", .enumValue(EnumValue(0)), notify: false)
        mesh.set("Scale", .vector3(Vector3(1.25, 1.25, 1.25)), notify: false)
        mesh.attachRaw(head)
        let face = InstanceFactory.create("Decal")
        face.name = "face"
        face.set("Texture", .string("rbxasset://textures/face.png"), notify: false)
        face.attachRaw(head)
        let la = part("Left Arm", Vector3(1, 2, 1), skin), ra = part("Right Arm", Vector3(1, 2, 1), skin)
        let ll = part("Left Leg", Vector3(1, 2, 1), pants), rl = part("Right Leg", Vector3(1, 2, 1), pants)
        for p in [root, torso, head, la, ra, ll, rl] { p.attachRaw(model) }
        PartData.setCFrame(root, origin)
        PartData.setCFrame(torso, origin)
        PartData.setCFrame(head, origin * .at(Vector3(0, 1.5, 0)))
        PartData.setCFrame(la, origin * .at(Vector3(-1.5, 0, 0)))
        PartData.setCFrame(ra, origin * .at(Vector3(1.5, 0, 0)))
        PartData.setCFrame(ll, origin * .at(Vector3(-0.5, -2, 0)))
        PartData.setCFrame(rl, origin * .at(Vector3(0.5, -2, 0)))
        let rot90 = CFrame.ry(.pi / 2), rotm90 = CFrame.ry(-.pi / 2)
        motor("RootJoint", root, torso, CFrame.rx(-.pi / 2) * .identity, CFrame.rx(-.pi / 2), parent: root)
        motor("Neck", torso, head, .at(Vector3(0, 1, 0)), .at(Vector3(0, -0.5, 0)), parent: torso)
        motor("Left Shoulder", torso, la, .at(Vector3(-1, 0.5, 0)) * rotm90, .at(Vector3(0.5, 0.5, 0)) * rotm90, parent: torso)
        motor("Right Shoulder", torso, ra, .at(Vector3(1, 0.5, 0)) * rot90, .at(Vector3(-0.5, 0.5, 0)) * rot90, parent: torso)
        motor("Left Hip", torso, ll, .at(Vector3(-1, -1, 0)) * rotm90, .at(Vector3(-0.5, 1, 0)) * rotm90, parent: torso)
        motor("Right Hip", torso, rl, .at(Vector3(1, -1, 0)) * rot90, .at(Vector3(0.5, 1, 0)) * rot90, parent: torso)
        let hum = InstanceFactory.create("Humanoid")
        hum.attachRaw(model)
        InstanceFactory.create("Animator").attachRaw(hum)
        model.set("PrimaryPart", .ref(root), notify: false)
        return model
    }

    /// Weld an accessory's Handle to the matching attachment on the character.
    static func attachAccessory(_ acc: Instance, to ch: Instance) {
        guard let handle = acc.findFirstChild("Handle"), handle.isA("BasePart") else { return }
        let att = handle.children.first { $0.className == "Attachment" }
        var target: Instance? = nil
        if let att {
            target = ch.descendants().first { $0.className == "Attachment" && $0.name == att.name && $0 !== att }
        }
        let host = target?.parent ?? ch.findFirstChild("Head")
        guard let hostPart = host else { return }
        let c0 = target?.get("CFrame")?.asCFrame ?? .at(Vector3(0, 0.5, 0))
        let c1 = att?.get("CFrame")?.asCFrame ?? .identity
        PartData.setCFrame(handle, PartData.cframe(hostPart) * c0 * c1.inverse)
        let w = InstanceFactory.create("Weld")
        w.name = "AccessoryWeld"
        w.set("Part0", .ref(handle), notify: false)
        w.set("Part1", .ref(hostPart), notify: false)
        w.set("C0", .cframe(c1), notify: false)
        w.set("C1", .cframe(c0), notify: false)
        w.attachRaw(handle)
        handle.set("CanCollide", .bool(false), notify: false)
    }
}
