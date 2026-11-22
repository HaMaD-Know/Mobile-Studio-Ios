import Foundation
import Luau
import StudioCore

/// Instance members visible to scripts (port of lua/InstanceApi.kt): properties, events, methods.
final class InstanceAPI {
    unowned let rt: ScriptRuntime
    private var warnedMissing = Set<String>()
    init(rt: ScriptRuntime) { self.rt = rt }

    static let universalEvents: Set<String> = ["ChildAdded", "ChildRemoved", "DescendantAdded", "DescendantRemoving", "Changed",
                                               "AncestryChanged", "Destroying", "AttributeChanged"]
    static let events: Set<String> = universalEvents.union([
        "Touched", "TouchEnded", "Heartbeat", "RenderStepped", "Stepped", "PreSimulation", "PostSimulation", "PreRender",
        "PlayerAdded", "PlayerRemoving", "CharacterAdded", "CharacterRemoving", "CharacterAppearanceLoaded", "Died",
        "HealthChanged", "Running", "Jumping", "StateChanged", "MoveToFinished", "FreeFalling", "Seated", "Climbing",
        "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "MouseButton2Click", "MouseButton2Down", "MouseButton2Up",
        "Activated", "MouseEnter", "MouseLeave", "MouseMoved", "FocusLost", "Focused", "Event", "OnServerEvent", "OnClientEvent",
        "MouseClick", "RightMouseClick", "MouseHoverEnter", "MouseHoverLeave", "Triggered", "TriggerEnded", "PromptShown",
        "PromptHidden", "PromptTriggered", "PromptTriggerEnded", "PromptButtonHoldBegan", "PromptButtonHoldEnded", "Completed",
        "SelectionChanged", "InputBegan", "InputEnded", "InputChanged", "TouchTapInWorld", "TouchTap", "TouchStarted",
        "TouchMoved", "TouchSwipe", "TouchLongPress", "TouchPinch", "Equipped", "Unequipped", "Deactivated", "Played", "Ended",
        "Paused", "Resumed", "Loaded", "Chatted", "Idled", "Button1Down", "Button1Up", "Button2Down", "Button2Up", "Move",
        "KeyDown", "KeyUp", "WheelForward", "WheelBackward", "JumpRequest", "LastInputTypeChanged", "TextChanged",
        "MessageReceived", "ChildRemoving", "DidLoop", "Stopped", "KeyframeReached", "OnUndo", "OnRedo",
        "PromptPurchaseFinished", "PromptGamePassPurchaseFinished", "PromptProductPurchaseFinished", "Close",
        "ReturnPressedFromOnScreenKeyboard", "MessageOut", "DragStart", "DragContinue", "DragEnd", "PlaybackStateChanged",
        "SoundLoaded", "AnimationPlayed", "OnIncomingMessage", "SendingMessage", "SelectionGained", "SelectionLost",
    ])

    // MARK: index

    func index(_ c: LuaCall, _ o: ScriptObject, _ key: String) throws -> Int32 {
        switch o {
        case .instance(let inst): return try indexInstance(c, inst, key)
        case .tween(let tw): return try indexTween(c, tw, key)
        case .track(let t): return try indexTrack(c, t, key)
        default:
            if let n = try DataTypes.index(c, o, key) { return n }
            throw LuaError("\(key) is not a valid member of \(o.typeName)")
        }
    }

    func newIndex(_ c: LuaCall, _ o: ScriptObject, _ key: String) throws {
        switch o {
        case .instance(let inst): try newIndexInstance(c, inst, key)
        case .track(let t): try trackNewIndex(c, t, key)
        default:
            if try DataTypes.newIndex(c, o, key) { return }
            throw LuaError("\(key) cannot be assigned to")
        }
    }

    func call(_ c: LuaCall, _ o: ScriptObject, _ method: String) throws -> Int32 {
        switch o {
        case .instance(let inst): return try callInstance(c, inst, method)
        case .tween(let tw): return try callTween(c, tw, method)
        case .track(let t): return try callTrack(c, t, method)
        default:
            if let n = try DataTypes.call(c, o, method) { return n }
            throw LuaError("\(method) is not a valid member of \(o.typeName)")
        }
    }

    private func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    private func indexInstance(_ c: LuaCall, _ inst: Instance, _ key0: String) throws -> Int32 {
        var key = key0
        if let f = key.first, f.isLowercase, Methods.has(inst, capitalized(key)) { key = capitalized(key) }
        switch key {
        case "Parent": c.push(inst.parent); return 1
        case "Name": c.push(inst.name); return 1
        case "ClassName": c.push(inst.className); return 1
        default: break
        }
        if Methods.has(inst, key) { rt.pushMethod(c.L, typeName: "Instance", key); return 1 }
        if inst.isA("LuaSourceContainer") && key == "Source" { c.push(inst.get("Source")?.asString ?? ""); return 1 }
        if let v = derived(inst, key) { c.push(v); return 1 }
        let stored = PropAccess.resolve(inst, key)
        if let v = inst.props[stored] { c.push(PropAccess.toScript(v, inst, stored)); return 1 }
        if InstanceAPI.events.contains(key) {
            if InstanceAPI.universalEvents.contains(key) || inst.findFirstChild(key) == nil {
                c.push(.signal(SignalRef(owner: inst, name: key))); return 1
            }
        }
        if let cb = rt.callbacks[ObjectIdentifier(inst)]?[key] { cb.push(c.L); return 1 }
        if let child = inst.findFirstChild(key) { c.push(child); return 1 }
        if let v = Defaults.value(inst, key) { c.push(v); return 1 }
        if warnedMissing.insert(inst.className + "." + key).inserted {
            rt.log(.warn, "\(key) is not a known member of \(inst.className) (treated as nil)")
        }
        c.pushNil()
        return 1
    }

    // MARK: derived properties (InstanceApi.getK)

    /// Values computed from other properties; nil when the key isn't special for this instance.
    func derived(_ inst: Instance, _ name: String) -> ScriptValue? {
        switch name {
        case "Archivable": return .bool(inst.archivable)
        default: break
        }
        if inst.isA("BasePart") {
            switch name {
            case "Size": return .object(.vector3(PartData.size(inst)))
            case "CFrame": return .object(.cframe(PartData.cframe(inst)))
            case "Position": return .object(.vector3(PartData.cframe(inst).position))
            case "Orientation": return .object(.vector3(PartData.cframe(inst).toOrientation * (180 / .pi)))
            case "Rotation": return .object(.vector3(PartData.cframe(inst).toEulerXYZ * (180 / .pi)))
            case "Color": return .object(.color3(PartData.color(inst)))
            case "BrickColor":
                if case .brickColor(let b)? = inst.get("BrickColor") { return .object(.brickColor(Int(b.number))) }
                return .object(.brickColor(BrickColors.closest(PartData.color(inst))))
            case "Shape": return .object(.enumItem(ScriptEnums.item("PartType", value: PartData.shape(inst).rawValue)!))
            case "Velocity", "AssemblyLinearVelocity":
                return .object(.vector3(rt.host?.velocity(of: inst) ?? inst.get("Velocity")?.asVector3 ?? .zero))
            case "RotVelocity", "AssemblyAngularVelocity": return .object(.vector3(inst.get("RotVelocity")?.asVector3 ?? .zero))
            case "Mass", "AssemblyMass": return .number(Double(Physics.mass(inst)))
            case "AssemblyRootPart": return .object(.instance(inst))
            case "AssemblyCenterOfMass", "CenterOfMass": return .object(.vector3(PartData.cframe(inst).position))
            case "PivotOffset": return .object(.cframe(inst.get("PivotOffset")?.asCFrame ?? .identity))
            case "ExtentsCFrame": return .object(.cframe(PartData.cframe(inst)))
            case "ResizeIncrement": return .number(1)
            case "ReceiveAge": return .number(0)
            default: break
            }
        }
        if inst.isA("Model") {
            switch name {
            case "WorldPivot": return .object(.cframe(ModelMath.pivot(inst)))
            case "PrimaryPart": return inst.get("PrimaryPart")?.asInstance.map { .object(.instance($0)) } ?? .nil_
            default: break
            }
        }
        if inst.className == "Humanoid" {
            switch name {
            case "Health": return .number(Double(inst.get("Health_XML")?.asFloat ?? inst.get("Health")?.asFloat ?? 100))
            case "MoveDirection": return .object(.vector3(rt.host?.moveDirection(inst) ?? .zero))
            case "RootPart": return inst.parent?.findFirstChild("HumanoidRootPart").map { .object(.instance($0)) } ?? .nil_
            case "FloorMaterial":
                let grounded = rt.host?.isGrounded(inst) ?? false
                return .object(.enumItem(ScriptEnums.item("Material", value: grounded ? 256 : 1792)!))
            case "SeatPart": return inst.get("SeatPart")?.asInstance.map { .object(.instance($0)) } ?? .nil_
            default: break
            }
        }
        if inst.isA("BaseScript") && name == "Enabled" { return .bool(inst.get("Disabled")?.asBool != true) }
        if inst.isA("GuiBase2d") {
            switch name {
            case "AbsoluteSize": return .object(.vector2(Vector2(Gui.abs(inst).w, Gui.abs(inst).h)))
            case "AbsolutePosition": return .object(.vector2(Vector2(Gui.abs(inst).x, Gui.abs(inst).y)))
            case "AbsoluteRotation": return .number(0)
            case "GuiState": return .object(.enumItem(EnumItem(enumType: "GuiState", name: "Idle", value: 0)))
            default: break
            }
        }
        if inst.isA("TextLabel") || inst.isA("TextButton") || inst.isA("TextBox") {
            if name == "TextBounds" {
                let text = inst.get("Text")?.asString ?? "", size = inst.get("TextSize")?.asFloat ?? 14
                return .object(.vector2(Vector2(Float(text.count) * size * 0.5, size)))
            }
            if name == "TextFits" { return .bool(true) }
            if name == "ContentText" { return .string(inst.get("Text")?.asString ?? "") }
        }
        if inst.className == "Workspace" {
            switch name {
            case "DistributedGameTime": return .number(rt.time)
            case "CurrentCamera": return inst.get("CurrentCamera")?.asInstance.map { .object(.instance($0)) } ?? .nil_
            case "Gravity": return .number(Double(inst.get("Gravity")?.asFloat ?? 196.2))
            default: break
            }
        }
        if inst.className == "Camera" {
            switch name {
            case "ViewportSize": return .object(.vector2(rt.host?.viewportSize() ?? Vector2(1280, 720)))
            case "Focus": return .object(.cframe(inst.get("Focus")?.asCFrame ?? PartData.cframe(inst)))
            default: break
            }
        }
        if inst.className == "Sound" {
            switch name {
            case "IsPlaying": return .bool(inst.get("Playing")?.asBool == true)
            case "IsPaused": return .bool(inst.get("Playing")?.asBool != true)
            case "IsLoaded": return .bool(true)
            case "TimeLength": return .number(inst.get("TimeLength")?.asFloat.map(Double.init) ?? 0)
            case "PlaybackLoudness": return .number(inst.get("Playing")?.asBool == true ? 200 : 0)
            default: break
            }
        }
        if inst.className == "Player" {
            switch name {
            case "Character": return inst.get("Character")?.asInstance.map { .object(.instance($0)) } ?? .nil_
            case "UserId": return .number(inst.get("UserId")?.asFloat.map(Double.init) ?? 1)
            case "DisplayName": return .string(inst.get("DisplayName")?.asString ?? inst.name)
            case "AccountAge": return .number(365)
            case "MembershipType": return .object(.enumItem(EnumItem(enumType: "MembershipType", name: "None", value: 0)))
            case "LocaleId": return .string("en-us")
            default: break
            }
        }
        if inst.className == "Players", name == "LocalPlayer" {
            return inst.children.first { $0.className == "Player" }.map { .object(.instance($0)) } ?? .nil_
        }
        if inst is DataModel {
            switch name {
            case "Workspace": return .object(.instance(rt.dm.workspace))
            case "PlaceId", "GameId", "CreatorId", "PlaceVersion": return .number(0)
            case "JobId", "PrivateServerId": return .string("")
            case "PrivateServerOwnerId": return .number(0)
            case "CreatorType": return .object(.enumItem(EnumItem(enumType: "CreatorType", name: "User", value: 0)))
            default: break
            }
            if let s = ServiceRegistry.byName(name) { return .object(.instance(rt.dm.getService(s))) }
        }
        return nil
    }

    // MARK: newindex

    private func newIndexInstance(_ c: LuaCall, _ inst: Instance, _ key: String) throws {
        if ["OnServerInvoke", "OnClientInvoke", "OnInvoke", "ProcessReceipt"].contains(key) || (c.isFunction(3) && !inst.props.contains(key)) {
            if c.isNil(3) { rt.callbacks[ObjectIdentifier(inst)]?[key] = nil } else { rt.callbacks[ObjectIdentifier(inst), default: [:]][key] = c.ref(3) }
            rt.fire(inst, "Callback:" + key)
            return
        }
        let v = rt.readValue(c.L, 3)
        try setValue(inst, key, v)
    }

    /// Read any property as a script value (used by tweens and Changed events).
    func getValue(_ inst: Instance, _ key: String) -> ScriptValue {
        if key == "Parent" { return inst.parent.map { .object(.instance($0)) } ?? .nil_ }
        if key == "Name" { return .string(inst.name) }
        if let v = derived(inst, key) { return v }
        let stored = PropAccess.resolve(inst, key)
        if let v = inst.props[stored] { return PropAccess.toScript(v, inst, stored) }
        return Defaults.value(inst, key) ?? .nil_
    }

    /// Assign a property from a script value (InstanceApi.setK).
    func setValue(_ inst: Instance, _ key: String, _ v: ScriptValue) throws {
        switch key {
        case "Parent":
            if case .object(.instance(let p)) = v {
                if inst.isService { throw LuaError("The Parent property of \(inst.name) is locked") }
                try setParent(inst, p)
            } else if v.isNil {
                if inst.isService { throw LuaError("The Parent property of \(inst.name) is locked") }
                try setParent(inst, nil)
            } else { throw LuaError("Unable to assign property Parent. Instance expected") }
            return
        case "Name":
            guard case .string(let s) = v else {
                if case .number(let n) = v { inst.name = n == n.rounded() ? String(Int64(n)) : String(n); return }
                throw LuaError("Unable to assign property Name. string expected")
            }
            inst.name = s
            return
        case "ClassName": throw LuaError("Unable to assign property ClassName. Property is read only")
        case "Archivable": inst.archivable = PropAccess.truthy(v); return
        default: break
        }
        if inst.isA("BasePart") {
            switch key {
            case "Size":
                guard case .object(.vector3(var s)) = v else { throw LuaError("Unable to assign property Size. Vector3 expected") }
                s = s.max(Vector3(0.001, 0.001, 0.001))
                if PartData.shape(inst) == .ball { let m = min(s.x, s.y, s.z); s = Vector3(m, m, m) }
                PartData.setSize(inst, s)
                return
            case "CFrame":
                guard case .object(.cframe(let cf)) = v else { throw LuaError("Unable to assign property CFrame. CFrame expected") }
                PartData.setCFrame(inst, cf)
                return
            case "Position":
                guard case .object(.vector3(let p)) = v else { throw LuaError("Unable to assign property Position. Vector3 expected") }
                PartData.setCFrame(inst, PartData.cframe(inst).withPosition(p))
                return
            case "Orientation", "Rotation":
                guard case .object(.vector3(let d)) = v else { throw LuaError("Unable to assign property \(key). Vector3 expected") }
                let r = d * (.pi / 180)
                let rot = key == "Orientation" ? CFrame.fromOrientation(r.x, r.y, r.z) : CFrame.angles(r.x, r.y, r.z)
                PartData.setCFrame(inst, rot.withPosition(PartData.cframe(inst).position))
                return
            case "Color":
                switch v {
                case .object(.color3(let col)): PartData.setColor(inst, col)
                case .object(.brickColor(let n)): PartData.setColor(inst, BrickColors.color(n))
                default: throw LuaError("Unable to assign property Color. Color3 expected")
                }
                return
            case "BrickColor":
                switch v {
                case .object(.brickColor(let n)):
                    PartData.setColor(inst, BrickColors.color(n))
                    if inst.props.contains("BrickColor") { inst.set("BrickColor", .brickColor(BrickColorV(Int32(n)))) }
                case .object(.color3(let col)): PartData.setColor(inst, col)
                case .string(let s): PartData.setColor(inst, BrickColors.color(BrickColors.byName(s) ?? 194))
                default: throw LuaError("Unable to assign property BrickColor. BrickColor expected")
                }
                return
            case "Velocity", "AssemblyLinearVelocity":
                guard case .object(.vector3(let vel)) = v else { throw LuaError("Unable to assign property \(key). Vector3 expected") }
                if let h = rt.host { h.setVelocity(of: inst, vel) } else { inst.set("Velocity", .vector3(vel)) }
                return
            case "RotVelocity", "AssemblyAngularVelocity":
                guard case .object(.vector3(let vel)) = v else { throw LuaError("Unable to assign property \(key). Vector3 expected") }
                inst.set("RotVelocity", .vector3(vel))
                return
            case "Shape":
                let n: Int
                switch v {
                case .object(.enumItem(let e)): n = e.value
                case .number(let x): n = Int(x)
                case .string(let s): n = ScriptEnums.item("PartType", s)?.value ?? 1
                default: throw LuaError("Unable to assign property Shape. EnumItem expected")
                }
                inst.set("shape", .enumValue(EnumValue(UInt32(max(0, n)))))
                return
            default: break
            }
        }
        if inst.isA("Model") {
            if key == "WorldPivot", case .object(.cframe(let cf)) = v { ModelMath.pivotTo(inst, cf); return }
        }
        if inst.className == "Humanoid", key == "Health" {
            guard case .number(let n) = v else { throw LuaError("Unable to assign property Health. number expected") }
            let maxH = inst.get("MaxHealth")?.asFloat ?? 100
            let old = inst.get("Health_XML")?.asFloat ?? 100
            let h = Float(min(Double(maxH), n))
            inst.set("Health_XML", .float(h))
            inst.propTypes["Health_XML"] = PropType.FLOAT
            if h <= 0 && old > 0 { rt.fire(inst, "Died") }
            return
        }
        if inst.isA("BaseScript") && key == "Enabled" { inst.set("Disabled", .bool(!PropAccess.truthy(v))); return }
        if inst.isA("LuaSourceContainer") && key == "Source" {
            guard case .string(let s) = v else { throw LuaError("Unable to assign property Source. string expected") }
            inst.set("Source", .string(s))
            return
        }
        let stored = PropAccess.resolve(inst, key)
        let existing = inst.props[stored]
        let pv = try PropAccess.fromScript(v, existing: existing, type: inst.propTypes[stored], inst: inst, prop: stored)
        let before = inst.props[stored]
        inst.set(stored, pv)
        // Instances outside the DataModel get no tree notifications; scripts still expect Changed.
        if inst.root() !== rt.dm && before != pv { rt.propChanged(inst, stored) }
        if inst.className == "Sound", stored == "Playing" {
            if case .bool(true) = pv { rt.host?.playSound(inst) } else { rt.host?.stopSound(inst) }
        }
    }

    func setParent(_ inst: Instance, _ p: Instance?) throws {
        if inst.destroyed { throw LuaError("The Parent property of \(inst.name) is locked, current parent: NULL, new parent \(p?.name ?? "NULL")") }
        do { try inst.setParent(p) } catch { throw LuaError(error.localizedDescription) }
    }
}

/// Instance methods (port of the method half of lua/InstanceApi.kt).
extension InstanceAPI {
    func callInstance(_ c: LuaCall, _ inst: Instance, _ m0: String) throws -> Int32 {
        var m = m0
        if let f = m.first, f.isLowercase, Methods.has(inst, capitalized(m)) { m = capitalized(m) }
        if let n = try Services.call(c, inst, m) { return n }
        switch m {
        case "FindFirstChild":
            c.push(inst.findFirstChild(try c.checkString(2, m), recursive: c.bool(3))); return 1
        case "FindFirstChildOfClass":
            let cls = try c.checkString(2, m)
            c.push(inst.children.first { $0.className == cls }); return 1
        case "FindFirstChildWhichIsA":
            c.push(inst.findFirstChildWhichIsA(try c.checkString(2, m), recursive: c.bool(3))); return 1
        case "FindFirstAncestor":
            let n = try c.checkString(2, m)
            var p = inst.parent
            while let cur = p, cur.name != n { p = cur.parent }
            c.push(p); return 1
        case "FindFirstAncestorOfClass":
            let n = try c.checkString(2, m)
            var p = inst.parent
            while let cur = p, cur.className != n { p = cur.parent }
            c.push(p); return 1
        case "FindFirstAncestorWhichIsA":
            let n = try c.checkString(2, m)
            var p = inst.parent
            while let cur = p, !cur.isA(n) { p = cur.parent }
            c.push(p); return 1
        case "FindFirstDescendant":
            let n = try c.checkString(2, m)
            c.push(inst.descendants().first { $0.name == n }); return 1
        case "GetChildren", "getChildren", "children":
            c.pushArray(inst.children) { c.push($0) }; return 1
        case "GetDescendants":
            c.pushArray(inst.descendants()) { c.push($0) }; return 1
        case "IsA", "isA":
            c.push(inst.isA(try c.checkString(2, m))); return 1
        case "IsAncestorOf":
            guard let o = c.instance(2) else { c.push(false); return 1 }
            c.push(o.isDescendant(of: inst)); return 1
        case "IsDescendantOf":
            guard let o = c.instance(2) else { c.push(inst.parent == nil); return 1 }
            c.push(inst.isDescendant(of: o)); return 1
        case "GetFullName":
            c.push(inst.fullName()); return 1
        case "GetDebugId":
            c.push(String(UInt(bitPattern: ObjectIdentifier(inst).hashValue), radix: 16)); return 1
        case "Clone", "clone":
            if !inst.archivable { c.pushNil(); return 1 }
            let copy = inst.cloneTree()
            c.push(copy); return 1
        case "Destroy", "destroy", "Remove", "remove":
            if inst.isService || inst is DataModel { throw LuaError("Cannot destroy \(inst.className)") }
            if m == "Remove" || m == "remove" { try? inst.setParent(nil) } else { inst.destroy() }
            return 0
        case "ClearAllChildren":
            for ch in inst.children where !ch.isService { ch.destroy() }
            return 0
        case "WaitForChild", "waitForChild":
            let name = try c.checkString(2, m)
            return try rt.waitForChild(c, inst, name, timeout: c.number(3))
        case "GetPropertyChangedSignal":
            let p = try c.checkString(2, m)
            c.push(.signal(SignalRef(owner: inst, name: "Changed:" + PropAccess.display(PropAccess.resolve(inst, p))))); return 1
        case "GetAttribute":
            let k = try c.checkString(2, m)
            if let v = inst.attributes[k] { c.push(PropAccess.toScript(v, nil, nil)) } else { c.pushNil() }
            return 1
        case "SetAttribute":
            let k = try c.checkString(2, m)
            let v = rt.readValue(c.L, 3)
            if v.isNil { inst.attributes[k] = nil } else { inst.attributes[k] = try PropAccess.plain(v, prop: k) }
            Instance.changeCount += 1
            rt.fire(inst, "AttributeChanged", [.string(k)])
            rt.fire(inst, "Attr:" + k)
            return 0
        case "GetAttributes":
            lua_createtable(c.L, 0, Int32(inst.attributes.count))
            for (k, v) in inst.attributes {
                c.push(PropAccess.toScript(v, nil, nil))
                k.withCString { lua_rawsetfield(c.L, -2, $0) }
            }
            return 1
        case "GetAttributeChangedSignal":
            c.push(.signal(SignalRef(owner: inst, name: "Attr:" + (try c.checkString(2, m))))); return 1
        case "AddTag":
            let t = try c.checkString(2, m)
            var tags = CollectionTags.tags(of: inst)
            if !tags.contains(t) {
                tags.append(t); CollectionTags.setTags(inst, tags)
                rt.fire(CollectionTags.signalOwner(rt, t), "Added", [.object(.instance(inst))])
            }
            return 0
        case "RemoveTag":
            let t = try c.checkString(2, m)
            var tags = CollectionTags.tags(of: inst)
            if tags.contains(t) {
                tags.removeAll { $0 == t }; CollectionTags.setTags(inst, tags)
                rt.fire(CollectionTags.signalOwner(rt, t), "Removed", [.object(.instance(inst))])
            }
            return 0
        case "HasTag":
            c.push(CollectionTags.tags(of: inst).contains(try c.checkString(2, m))); return 1
        case "GetTags":
            c.pushArray(CollectionTags.tags(of: inst)) { c.push($0) }; return 1
        case "GetActor":
            var p = inst.parent
            while let cur = p, cur.className != "Actor" { p = cur.parent }
            c.push(p); return 1
        case "IsPropertyModified": c.push(false); return 1
        case "ResetPropertyToDefault": return 0
        case "GetStyled": c.push(getValue(inst, try c.checkString(2, m))); return 1
        default: break
        }
        if let n = try TerrainAPI.call(c, inst, m) { return n }
        if let n = try PhysicalAPI.call(c, inst, m, self) { return n }
        if let n = try HumanoidAPI.call(c, inst, m, self) { return n }
        if let n = try MiscAPI.call(c, inst, m, self) { return n }
        throw LuaError("\(m) is not a valid member of \(inst.className) \"\(inst.fullName())\"")
    }

    // MARK: Tween objects

    func indexTween(_ c: LuaCall, _ tw: Tween, _ key: String) throws -> Int32 {
        switch key {
        case "PlaybackState":
            c.push(.enumItem(ScriptEnums.item("PlaybackState", value: tw.state.rawValue)!)); return 1
        case "Instance": c.push(tw.inst); return 1
        case "TweenInfo": c.push(.tweenInfo(tw.info)); return 1
        case "Completed", "PlaybackStateChanged": c.push(.signal(SignalRef(owner: tw, name: key))); return 1
        case "ClassName": c.push("Tween"); return 1
        case "Name": c.push("Tween"); return 1
        case "Play", "Pause", "Cancel", "Destroy", "IsA", "GetPropertyChangedSignal":
            rt.pushMethod(c.L, typeName: "Tween", key); return 1
        default: throw LuaError("\(key) is not a valid member of Tween")
        }
    }

    func callTween(_ c: LuaCall, _ tw: Tween, _ m: String) throws -> Int32 {
        switch m {
        case "Play": rt.playTween(tw)
        case "Pause": if tw.state == .playing || tw.state == .delayed { tw.state = .paused }
        case "Cancel":
            tw.state = .cancelled
            rt.tweens.removeAll { $0 === tw }
            rt.fire(tw, "Completed", [.object(.enumItem(ScriptEnums.item("PlaybackState", "Cancelled")!))])
        case "Destroy": tw.state = .cancelled; rt.tweens.removeAll { $0 === tw }
        case "IsA": c.push(["Tween", "TweenBase", "Instance"].contains(try c.checkString(2, m))); return 1
        case "GetPropertyChangedSignal": c.push(.signal(SignalRef(owner: tw, name: "Changed:" + (try c.checkString(2, m))))); return 1
        default: throw LuaError("\(m) is not a valid member of Tween")
        }
        return 0
    }

    // MARK: AnimationTrack objects

    func indexTrack(_ c: LuaCall, _ t: AnimTrackRef, _ key: String) throws -> Int32 {
        switch key {
        case "IsPlaying": c.push(t.isPlaying); return 1
        case "Speed": c.push(t.speed); return 1
        case "WeightCurrent", "WeightTarget": c.push(t.weight); return 1
        case "Looped": c.push(t.looped); return 1
        case "TimePosition": c.push(t.timePosition); return 1
        case "Length": c.push(t.length); return 1
        case "Animation": c.push(t.animation); return 1
        case "Name": c.push(t.animation.name); return 1
        case "ClassName": c.push("AnimationTrack"); return 1
        case "Priority": c.push(.enumItem(ScriptEnums.item("AnimationPriority", value: t.priority) ?? ScriptEnums.item("AnimationPriority", "Action")!)); return 1
        case "Stopped", "Ended", "DidLoop", "KeyframeReached": c.push(.signal(SignalRef(owner: t, name: key))); return 1
        case "Play", "Stop", "AdjustSpeed", "AdjustWeight", "GetMarkerReachedSignal", "GetTimeOfKeyframe", "Destroy", "IsA":
            rt.pushMethod(c.L, typeName: "AnimationTrack", key); return 1
        default: throw LuaError("\(key) is not a valid member of AnimationTrack")
        }
    }

    func trackNewIndex(_ c: LuaCall, _ t: AnimTrackRef, _ key: String) throws {
        switch key {
        case "Looped": t.looped = c.bool(3); rt.host?.adjustTrack(t, speed: nil, weight: nil, looped: t.looped, time: nil)
        case "TimePosition": let v = try c.checkFloat(3); rt.host?.adjustTrack(t, speed: nil, weight: nil, looped: nil, time: v)
        case "Priority": t.priority = c.enumItem(3)?.value ?? Int(c.number(3) ?? 2)
        default: throw LuaError("\(key) cannot be assigned to")
        }
    }

    func callTrack(_ c: LuaCall, _ t: AnimTrackRef, _ m: String) throws -> Int32 {
        switch m {
        case "Play": rt.host?.playTrack(t, fade: c.optFloat(2, 0.1), weight: c.optFloat(3, 1), speed: c.optFloat(4, 1))
        case "Stop": rt.host?.stopTrack(t, fade: c.optFloat(2, 0.1))
        case "AdjustSpeed": t.speed = c.optFloat(2, 1); rt.host?.adjustTrack(t, speed: t.speed, weight: nil, looped: nil, time: nil)
        case "AdjustWeight": t.weight = c.optFloat(2, 1); rt.host?.adjustTrack(t, speed: nil, weight: t.weight, looped: nil, time: nil)
        case "GetMarkerReachedSignal": c.push(.signal(SignalRef(owner: t, name: "Marker:" + (try c.checkString(2, m))))); return 1
        case "GetTimeOfKeyframe": c.push(0.0); return 1
        case "Destroy": rt.host?.stopTrack(t, fade: 0)
        case "IsA": c.push(["AnimationTrack", "Instance"].contains(try c.checkString(2, m))); return 1
        default: throw LuaError("\(m) is not a valid member of AnimationTrack")
        }
        return 0
    }
}

/// Which method names exist on which classes (InstanceApi.methodAllowed).
enum Methods {
    static let common: Set<String> = [
        "FindFirstChild", "FindFirstChildOfClass", "FindFirstChildWhichIsA", "FindFirstAncestor", "FindFirstAncestorOfClass",
        "FindFirstAncestorWhichIsA", "FindFirstDescendant", "GetChildren", "GetDescendants", "IsA", "IsAncestorOf", "IsDescendantOf",
        "GetFullName", "GetDebugId", "Clone", "Destroy", "Remove", "ClearAllChildren", "WaitForChild", "GetPropertyChangedSignal",
        "GetAttribute", "SetAttribute", "GetAttributes", "GetAttributeChangedSignal", "AddTag", "RemoveTag", "HasTag", "GetTags",
        "GetActor", "IsPropertyModified", "ResetPropertyToDefault", "GetStyled",
    ]
    static let byClass: [String: Set<String>] = [
        "BasePart": ["GetMass", "GetConnectedParts", "GetJoints", "GetTouchingParts", "ApplyImpulse", "ApplyAngularImpulse",
                     "ApplyImpulseAtPosition", "GetVelocityAtPosition", "Resize", "CanCollideWith", "GetRootPart", "SetNetworkOwner",
                     "GetNetworkOwner", "SetNetworkOwnershipAuto", "CanSetNetworkOwnership", "IsGrounded", "BreakJoints", "MakeJoints",
                     "GetPivot", "PivotTo", "SubtractAsync", "UnionAsync", "IntersectAsync", "GetClosestPointOnSurface", "AngularAccelerationToTorque", "TorqueToAngularAcceleration"],
        "Model": ["GetPivot", "PivotTo", "MoveTo", "GetBoundingBox", "GetExtentsSize", "GetModelCFrame", "GetModelSize",
                  "SetPrimaryPartCFrame", "GetPrimaryPartCFrame", "TranslateBy", "ScaleTo", "GetScale", "BreakJoints", "MakeJoints",
                  "ResetOrientationToIdentity", "AddPersistentPlayer", "RemovePersistentPlayer"],
        "Humanoid": ["TakeDamage", "Move", "MoveTo", "ChangeState", "GetState", "SetStateEnabled", "GetStateEnabled", "LoadAnimation",
                     "GetPlayingAnimationTracks", "EquipTool", "UnequipTools", "AddAccessory", "GetAccessories", "RemoveAccessories",
                     "ApplyDescription", "GetAppliedDescription", "BuildRigFromAttachments", "GetLimb", "ReplaceBodyPartR15", "GetBodyPartR15",
                     "GetMoveVelocity"],
        "Animator": ["LoadAnimation", "GetPlayingAnimationTracks", "StepAnimations"],
        "Terrain": TerrainAPI.methods,
        "AnimationController": ["LoadAnimation", "GetPlayingAnimationTracks"],
        "WorldRoot": ["Raycast", "Blockcast", "Spherecast", "Shapecast", "GetPartBoundsInBox", "GetPartBoundsInRadius", "GetPartsInPart",
                      "FindPartOnRay", "FindPartOnRayWithIgnoreList", "FindPartOnRayWithWhitelist", "FindPartsInRegion3",
                      "FindPartsInRegion3WithIgnoreList", "FindPartsInRegion3WithWhiteList", "IsRegion3Empty", "IsRegion3EmptyWithIgnoreList",
                      "ArePartsTouchingOthers", "BulkMoveTo", "GetServerTimeNow", "GetRealPhysicsFPS", "GetNumAwakeParts", "GetPhysicsThrottling",
                      "JoinToOutsiders", "UnjoinFromOutsiders", "ZoomToExtents"],
        "Camera": ["ScreenPointToRay", "ViewportPointToRay", "WorldToViewportPoint", "WorldToScreenPoint", "GetPartsObscuringTarget",
                   "Interpolate", "ZoomToExtents", "GetRenderCFrame", "GetRoll", "SetRoll"],
        "Sound": ["Play", "Stop", "Pause", "Resume"],
        "BindableEvent": ["Fire"],
        "BindableFunction": ["Invoke"],
        "RemoteEvent": ["FireServer", "FireClient", "FireAllClients"],
        "UnreliableRemoteEvent": ["FireServer", "FireClient", "FireAllClients"],
        "RemoteFunction": ["InvokeServer", "InvokeClient"],
        "Player": ["LoadCharacter", "Kick", "GetMouse", "IsInGroup", "GetRankInGroup", "GetRoleInGroup", "IsFriendsWith",
                   "HasAppearanceLoaded", "GetNetworkPing", "DistanceFromCharacter", "GetFriendsOnline", "ClearCharacterAppearance",
                   "LoadCharacterAsync", "RequestStreamAroundAsync", "GetJoinData"],
        "GuiObject": ["TweenPosition", "TweenSize", "TweenSizeAndPosition"],
        "TextBox": ["CaptureFocus", "ReleaseFocus", "IsFocused"],
        "Tool": ["Activate", "Deactivate"],
        "ParticleEmitter": ["Emit", "Clear"],
        "ProximityPrompt": ["InputHoldBegin", "InputHoldEnd"],
        "ClickDetector": [],
        "ValueBase": [],
        "Explosion": [],
        "Script": [],
        "Constraint": [],
        "Beam": ["SetTextureOffset"],
        "Trail": ["Clear"],
    ]
    static func has(_ inst: Instance, _ m: String) -> Bool {
        if common.contains(m) { return true }
        if Services.methods(inst).contains(m) { return true }
        for (cls, set) in byClass where set.contains(m) && inst.isA(cls) { return true }
        return false
    }
}

/// Default values for well-known properties an instance doesn't store (keeps scripts from reading nil).
enum Defaults {
    static func value(_ inst: Instance, _ key: String) -> ScriptValue? {
        if inst.isA("BasePart") {
            switch key {
            case "Anchored", "Locked", "Massless": return .bool(false)
            case "CanCollide", "CanTouch", "CanQuery", "CastShadow": return .bool(true)
            case "Transparency", "Reflectance", "LocalTransparencyModifier": return .number(0)
            case "Material": return .object(.enumItem(ScriptEnums.item("Material", value: PartData.material(inst))!))
            case "CollisionGroup": return .string("Default")
            case "CustomPhysicalProperties": return .nil_
            default: break
            }
        }
        if inst.className == "Humanoid" {
            switch key {
            case "WalkSpeed": return .number(16)
            case "JumpPower": return .number(50)
            case "JumpHeight": return .number(7.2)
            case "UseJumpPower": return .bool(true)
            case "MaxHealth": return .number(100)
            case "HipHeight": return .number(0)
            case "Sit", "PlatformStand", "Jump", "AutoRotate", "AutoJumpEnabled", "BreakJointsOnDeath", "RequiresNeck":
                return .bool(["AutoRotate", "AutoJumpEnabled", "BreakJointsOnDeath", "RequiresNeck"].contains(key))
            case "MaxSlopeAngle": return .number(89)
            case "DisplayName": return .string("")
            case "WalkToPoint": return .object(.vector3(.zero))
            case "WalkToPart": return .nil_
            case "RigType": return .object(.enumItem(ScriptEnums.item("HumanoidRigType", "R6")!))
            case "NameDisplayDistance", "HealthDisplayDistance": return .number(100)
            case "CameraOffset": return .object(.vector3(.zero))
            default: break
            }
        }
        if inst.isA("GuiObject") {
            switch key {
            case "Visible", "Active": return .bool(key == "Visible")
            case "BackgroundTransparency", "Rotation", "BorderSizePixel", "LayoutOrder": return .number(0)
            case "ZIndex": return .number(1)
            case "AnchorPoint": return .object(.vector2(.zero))
            case "BorderColor3": return .object(.color3(Color3.fromRGB(27, 42, 53)))
            case "ClipsDescendants": return .bool(false)
            case "TextTransparency", "TextStrokeTransparency", "ImageTransparency": return .number(key == "TextStrokeTransparency" ? 1 : 0)
            case "TextScaled", "TextWrapped", "RichText": return .bool(false)
            case "ImageColor3", "TextStrokeColor3": return .object(.color3(key == "ImageColor3" ? Color3(1, 1, 1) : Color3(0, 0, 0)))
            case "AutoButtonColor", "Selectable": return .bool(true)
            default: break
            }
        }
        if inst.className == "Sound" {
            switch key {
            case "PlaybackSpeed", "Pitch": return .number(1)
            case "TimePosition": return .number(0)
            case "RollOffMaxDistance": return .number(10000)
            case "RollOffMinDistance": return .number(10)
            default: break
            }
        }
        if inst.className == "Animation", key == "AnimationId" { return .string("") }
        if inst.className == "Lighting" {
            switch key {
            case "TimeOfDay":
                let ct = inst.get("ClockTime")?.asFloat ?? 14
                let h = Int(ct), mm = Int((ct - Float(h)) * 60)
                return .string(String(format: "%02d:%02d:00", h, mm))
            case "FogEnd": return .number(100000)
            case "FogStart": return .number(0)
            case "FogColor": return .object(.color3(Color3.fromRGB(192, 192, 192)))
            case "GeographicLatitude": return .number(41.7)
            case "ExposureCompensation", "EnvironmentDiffuseScale", "EnvironmentSpecularScale", "ShadowSoftness": return .number(0)
            case "GlobalShadows": return .bool(true)
            default: break
            }
        }
        if inst.className == "ProximityPrompt" {
            switch key {
            case "Enabled", "RequiresLineOfSight": return .bool(true)
            case "KeyboardKeyCode": return .object(.enumItem(ScriptEnums.item("KeyCode", "E")!))
            case "HoldDuration": return .number(0)
            case "MaxActivationDistance": return .number(10)
            case "ActionText": return .string("Interact")
            case "ObjectText": return .string("")
            default: break
            }
        }
        if inst.isA("ValueBase"), key == "Value" { return .nil_ }
        if inst.className == "Tool" {
            switch key {
            case "Enabled", "RequiresHandle", "CanBeDropped", "ManualActivationOnly": return .bool(key != "ManualActivationOnly")
            case "Grip": return .object(.cframe(.identity))
            case "ToolTip": return .string("")
            default: break
            }
        }
        return nil
    }
}
