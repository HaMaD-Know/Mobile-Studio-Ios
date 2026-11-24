import Foundation
import StudioCore

/// Play mode (port of engine/PlaySession.kt): runs the place's scripts against a copy of the edit
/// model, simulates characters and unanchored parts, drives the camera and feeds input to scripts.
public final class PlaySession: ScriptHost {
    public let dm: DataModel
    public private(set) var rt: ScriptRuntime!
    public private(set) var player: Instance?
    public private(set) var character: Instance?
    let physics = PhysicsWorld()
    private var startedScripts = Set<ObjectIdentifier>()
    private var running = false

    // Input (set by the app)
    public var moveInput = Vector2.zero            // joystick: x right, y forward
    public var controlsEnabled = true
    public var shiftLock = false
    private var jumpRequested = false
    private var scriptMove: (dir: Vector3, until: Double)?
    private var moveToTarget: Vector3?

    // Camera
    public var viewport = Vector2(1280, 720)
    public private(set) var cameraCFrame = CFrame.lookAt(Vector3(0, 10, 20), .zero)
    public var fieldOfView: Float = 70
    private var camYaw: Float = 0
    private var camPitch: Float = -0.35
    private var camDistance: Float = 12.5

    // Character state
    private var grounded = false
    private var charVelocity = Vector3.zero
    private var lastMoveDir = Vector3.zero
    private var animTime: Float = 0
    private var deadTimer: Float?
    private var touching = Set<PairKey>()
    private var seat: Instance?
    private var seatCooldown: Float = 0
    private var virtualKeys = Set<String>()
    private var lastCamDrag: Double = -10
    private var tracks: [AnimTrackRef] = []

    public var seatedVehicle: Instance? { seat?.className == "VehicleSeat" ? seat : nil }
    public var vehicleSpeed: Float {
        guard let s = seatedVehicle, let v = physics.body(of: s)?.velocity else { return 0 }
        return Vector3(v.x, 0, v.z).magnitude
    }

    // HUD state the app reads
    public private(set) var nearestPrompt: Instance?
    public private(set) var chatLines: [(String, String)] = []
    public private(set) var actions: [String: (title: String, fn: LuaRef)] = [:]
    public var onSound: (Instance, Bool) -> Void = { _, _ in }
    let animLib = AnimLibrary()
    let animPlayer = AnimPlayer()
    private var defaultPose = ""
    private var pendingEmote: (key: String, id: String)?
    /// Asset loader (content id -> bytes) the app provides for animations.
    public var assetLoader: ((String, @escaping (Data?) -> Void) -> Void)? {
        get { animLib.loader }
        set { animLib.loader = newValue }
    }
    public var onOutput: (OutputLevel, String) -> Void = { _, s in print(s) }

    public init(editModel: DataModel) {
        dm = editModel.cloneModel()
        rt = ScriptRuntime(dm: dm, isPlay: true) { [unowned self] rt in
            rt.addGlobalTable("__MobileStudioPlayer", [
                "setControlsEnabled": { [unowned self] c in self.controlsEnabled = c.bool(1); return 0 },
                "getMoveVector": { [unowned self] c in c.push(Vector3(self.moveInput.x, 0, -self.moveInput.y)) },
                "setShiftLock": { [unowned self] c in self.shiftLock = c.bool(1); return 0 },
                "isShiftLock": { [unowned self] c in c.push(self.shiftLock) },
            ])
        }
        rt.host = self
        rt.onOutput = { [unowned self] l, s in self.onOutput(l, s) }
    }

    deinit { stop() }

    // MARK: lifecycle

    public func start() {
        running = true
        Gui.viewport = viewport
        onOutput(.info, "Playtest started")
        setupTextChat()
        for s in dm.descendants() where s.className == "Script" { maybeRunScript(s) }

        let players = dm.getService("Players")
        let p = InstanceFactory.create("Player")
        p.name = "Player1"
        p.set("UserId", .int64(1), notify: false)
        p.set("DisplayName", .string("Player1"), notify: false)
        p.set("Character", .ref(nil), notify: false)
        p.set("Neutral", .bool(true), notify: false)
        p.set("CameraMaxZoomDistance", .float(dm.findService("StarterPlayer")?.get("CameraMaxZoomDistance")?.asFloat ?? 128), notify: false)
        p.set("CameraMinZoomDistance", .float(dm.findService("StarterPlayer")?.get("CameraMinZoomDistance")?.asFloat ?? 0.5), notify: false)
        for (cls, name) in [("Backpack", "Backpack"), ("PlayerGui", "PlayerGui"), ("PlayerScripts", "PlayerScripts")] {
            let i = InstanceFactory.create(cls)
            i.name = name
            i.attachRaw(p)
        }
        addPlayerModule(p.findFirstChild("PlayerScripts")!)
        player = p
        try? p.setParent(players)
        rt.fire(players, "PlayerAdded", [.object(.instance(p))])
        if let sps = dm.findService("StarterPlayer")?.findFirstChild("StarterPlayerScripts") {
            for c in sps.children where c.name != "PlayerModule" { try? c.cloneTree().setParent(p.findFirstChild("PlayerScripts")) }
        }
        resetGui()
        if let pack = dm.findService("StarterPack") { for c in pack.children { try? c.cloneTree().setParent(p.findFirstChild("Backpack")) } }
        if let rf = dm.findService("ReplicatedFirst") { for d in rf.descendants() { maybeRunScript(d) } }
        spawnCharacter()
        physics.rebuild(dm.workspace, character: character)
    }

    public func stop() {
        guard running else { return }
        running = false
        seat = nil
        virtualKeys.removeAll()
        rt.fire(dm, "Close")
        rt.shutdown()
        onOutput(.info, "Playtest stopped")
    }

    private func setupTextChat() {
        let tcs = dm.getService("TextChatService")
        var folder = tcs.findFirstChild("TextChannels")
        if folder == nil {
            let f = InstanceFactory.create("Folder"); f.name = "TextChannels"; f.archivable = false; f.attachRaw(tcs); folder = f
        }
        for n in ["RBXGeneral", "RBXSystem"] where folder!.findFirstChild(n) == nil {
            let ch = Instance("TextChannel"); ch.name = n; ch.archivable = false; ch.attachRaw(folder!)
        }
    }

    private func addPlayerModule(_ ps: Instance) {
        func module(_ name: String, _ src: String, _ parent: Instance) -> Instance {
            let m = InstanceFactory.create("ModuleScript")
            m.name = name
            m.set("Source", .string(src), notify: false)
            m.attachRaw(parent)
            return m
        }
        let pm = module("PlayerModule", """
        local bridge = __MobileStudioPlayer
        local Controls = {}
        Controls.__index = Controls
        function Controls:Enable(enable) bridge.setControlsEnabled(enable ~= false) end
        function Controls:Disable() bridge.setControlsEnabled(false) end
        function Controls:GetMoveVector() return bridge.getMoveVector() end
        function Controls:GetActiveController() return self end
        function Controls:SelectTouchModule() end
        function Controls:GetIsJumping() return false end
        local controls = setmetatable({}, Controls)
        local Cameras = {}
        Cameras.__index = Cameras
        function Cameras:GetCameraControlChoice() return nil end
        function Cameras:SetIsMouseLocked(on) bridge.setShiftLock(on) end
        function Cameras:GetIsMouseLocked() return bridge.isShiftLock() end
        local cameras = setmetatable({}, Cameras)
        local PlayerModule = {}
        function PlayerModule:GetControls() return controls end
        function PlayerModule:GetCameras() return cameras end
        function PlayerModule:GetClickToMoveController() return controls end
        return PlayerModule
        """, ps)
        _ = module("ControlModule", "local pm = require(script.Parent)\nreturn pm:GetControls()", pm)
        _ = module("CameraModule", "local pm = require(script.Parent)\nreturn pm:GetCameras()", pm)
    }

    /// Copy StarterGui into PlayerGui (ResetOnSpawn guis are replaced on respawn).
    private func resetGui(initial: Bool = true) {
        guard let p = player, let pg = p.findFirstChild("PlayerGui"), let sg = dm.findService("StarterGui") else { return }
        if !initial {
            for g in pg.children where g.get("ResetOnSpawn")?.asBool != false { g.destroy() }
        }
        for g in sg.children {
            if !initial && g.get("ResetOnSpawn")?.asBool == false { continue }
            try? g.cloneTree().setParent(pg)
        }
    }

    // MARK: scripts

    private func isUnder(_ s: Instance, _ cls: String) -> Bool {
        var p = s.parent
        while let cur = p { if cur.className == cls { return true }; p = cur.parent }
        return false
    }

    private func isRunnable(_ s: Instance) -> Bool {
        if s.get("Disabled")?.asBool == true { return false }
        let ctx = Int(s.get("RunContext")?.asEnum ?? 0)
        let clientPlaces = (player.map { s.isDescendant(of: $0) } ?? false) || (character.map { s.isDescendant(of: $0) } ?? false) || isUnder(s, "ReplicatedFirst")
        let inBackpack: Bool = {
            var p = s.parent
            while let cur = p { if cur.className == "Backpack" && cur.parent === player { return true }; p = cur.parent }
            return false
        }()
        switch s.className {
        case "LocalScript": return clientPlaces
        case "Script":
            switch ctx {
            case 0: return isUnder(s, "Workspace") || isUnder(s, "ServerScriptService") || inBackpack
            case 1: return isUnder(s, "Workspace") || isUnder(s, "ServerScriptService") || isUnder(s, "ReplicatedStorage") || inBackpack
            case 2: return clientPlaces || isUnder(s, "Workspace") || isUnder(s, "ReplicatedStorage")
            default: return false
            }
        default: return false
        }
    }

    public func maybeRunScript(_ s: Instance) {
        guard running, !rt.stopped, s.isA("BaseScript"), !startedScripts.contains(ObjectIdentifier(s)), isRunnable(s) else { return }
        startedScripts.insert(ObjectIdentifier(s))
        rt.runScript(s)
    }

    // MARK: TreeListener forwarding from the runtime

    private static func isPhysicsObject(_ i: Instance) -> Bool {
        i.isA("BasePart") || i.isA("JointInstance") || i.className == "WeldConstraint"
            || i.isA("Constraint") || i.isA("BodyMover") || i.className == "Attachment"
    }

    public func childAdded(_ parent: Instance, _ child: Instance) {
        maybeRunScript(child)
        for d in child.descendants() { maybeRunScript(d) }
        if Self.isPhysicsObject(child) || child.descendants().contains(where: { Self.isPhysicsObject($0) }) {
            physics.dirty = true
        }
    }
    public func childRemoved(_ parent: Instance, _ child: Instance) {
        if Self.isPhysicsObject(child) || !child.children.isEmpty { physics.dirty = true }
        if child === character { character = nil }
        if child === seat { seat = nil; virtualKeys.removeAll() }
    }
    public func propChanged(_ inst: Instance, _ name: String) {
        if name == "Anchored" || name == "CanCollide" || name == "Part0" || name == "Part1"
            || name == "Attachment0" || name == "Attachment1" || name == "Enabled" || name == "Disabled" || name == "Massless" {
            physics.dirty = true
        }
        if inst.isA("BasePart"), name == "CFrame" || name == "size" || name == "Size" { physics.moved(inst) }
    }

    // MARK: characters

    /// "Play Here": the first spawn happens at this point instead of a SpawnLocation.
    public var spawnOverride: Vector3?

    private func spawnLocation() -> CFrame {
        if let p = spawnOverride { return .at(p + Vector3(0, 3, 0)) }
        let spawns = dm.workspace.descendants().filter { $0.className == "SpawnLocation" && $0.get("Enabled")?.asBool != false }
        guard let s = spawns.randomElement() else { return .at(Vector3(0, 5, 0)) }
        let cf = PartData.cframe(s), size = PartData.size(s)
        return .at(cf.position + Vector3(0, size.y / 2 + 3, 0))
    }

    public func spawnCharacter() {
        guard let p = player else { return }
        if let old = character { rt.fire(p, "CharacterRemoving", [.object(.instance(old))]); old.destroy() }
        let ch: Instance
        let sp = dm.findService("StarterPlayer")
        if let tpl = sp?.findFirstChild("StarterCharacter"), tpl.isA("Model") {
            ch = tpl.cloneTree()
            ch.name = p.name
            ModelMath.pivotTo(ch, spawnLocation())
        } else if let custom = customCharacter {
            ch = CharacterBuilder.wrapCustomCharacter(custom, name: p.name)
            ModelMath.pivotTo(ch, spawnLocation())
        } else {
            ch = wantR15 ? CharacterBuilder.buildR15(name: p.name, at: spawnLocation())
                         : CharacterBuilder.buildR6(name: p.name, at: spawnLocation())
            if !wantR15 { CharacterBuilder.addR6Attachments(ch) }
            let loadApp = sp?.get("LoadCharacterAppearance")?.asBool != false
            if loadApp, let avatar { CharacterBuilder.apply(avatar, to: ch) }
        }
        if let scripts = dm.findService("StarterPlayer")?.findFirstChild("StarterCharacterScripts") {
            for s in scripts.children { s.cloneTree().attachRaw(ch) }
        }
        DefaultAnimate.attach(to: ch, r15: ch.findFirstChild("UpperTorso") != nil)
        character = ch
        defaultPose = ""
        animPlayer.clear()
        charVelocity = .zero
        deadTimer = nil
        seat = nil
        seatCooldown = 0
        virtualKeys.removeAll()
        p.set("Character", .ref(ch))
        try? ch.setParent(dm.workspace)
        resetGui(initial: false)
        if let root = ch.findFirstChild("HumanoidRootPart") {
            camYaw = 0; camPitch = -0.35
            cameraCFrame = .lookAt(PartData.cframe(root).position + Vector3(0, 6, 12), PartData.cframe(root).position)
        }
        if let cam = dm.workspace.get("CurrentCamera")?.asInstance { cam.set("CameraSubject", .ref(ch.findFirstChildOfClass("Humanoid"))) }
        physics.dirty = true
        rt.fire(p, "CharacterAdded", [.object(.instance(ch))])
        rt.fire(p, "CharacterAppearanceLoaded", [.object(.instance(ch))])
    }

    /// The player's avatar (set by the app once it has loaded it; respawns to apply).
    public var avatar: AvatarSpec? {
        didSet { if running, character != nil, deadTimer == nil { spawnCharacter() } }
    }

    /// Optional custom Model or BasePart to spawn as instead of a rig.
    public var customCharacter: Instance? {
        didSet { if running, character != nil, deadTimer == nil { spawnCharacter() } }
    }

    /// StarterPlayer.GameSettingsAvatar: 0 R6, 1 R15, 2 player's choice (PlaySession.wantR15).
    private var wantR15: Bool {
        switch dm.findService("StarterPlayer")?.get("GameSettingsAvatar")?.asEnum ?? 2 {
        case 0: return false
        case 1: return true
        default: return avatar?.r15 ?? false
        }
    }

    private var humanoid: Instance? { character?.findFirstChildOfClass("Humanoid") }
    private var rootPart: Instance? { character?.findFirstChild("HumanoidRootPart") ?? character?.findFirstChild("Torso") }

    // MARK: frame

    public func step(_ dt0: Float) {
        guard running else { return }
        let dt = min(dt0, 1 / 20)
        Gui.viewport = viewport
        let runService = dm.getService("RunService")
        rt.fire(runService, "Stepped", [.number(rt.time), .number(Double(dt))])
        rt.fire(runService, "PreSimulation", [.number(Double(dt))])
        if physics.dirty { physics.rebuild(dm.workspace, character: character) }
        stepCharacter(dt)
        physics.step(dt, gravity: dm.workspace.get("Gravity")?.asFloat ?? 196.2, exclude: character)
        physics.solveJoints()
        if let s = seat, let ch = character, s.parent != nil { syncCharacterToSeat(ch, s) }
        checkTouches()
        killFallen()
        rt.fire(runService, "PostSimulation", [.number(Double(dt))])
        rt.fire(runService, "Heartbeat", [.number(Double(dt))])
        rt.step(Double(dt))
        updateCamera(dt)
        animate(dt)
        updatePrompts()
        rt.fire(runService, "RenderStepped", [.number(Double(dt))])
        rt.fire(runService, "PreRender", [.number(Double(dt))])
        if let t = deadTimer {
            deadTimer = t - dt
            if t - dt <= 0 { deadTimer = nil; spawnCharacter() }
        }
    }

    // MARK: character controller (PlaySession.stepCharacter / collideCharacter)

    private func stepCharacter(_ dt: Float) {
        guard let hum = humanoid, let root = rootPart else { return }
        let health = hum.get("Health_XML")?.asFloat ?? 100
        if health <= 0 {
            if deadTimer == nil { die() }
            return
        }
        if seatCooldown > 0 { seatCooldown = max(0, seatCooldown - dt) }
        if let s = seat {
            if s.parent == nil || s.get("Occupant")?.asInstance !== hum || hum.get("Sit")?.asBool == false {
                leaveSeat(hum, jump: false)
                jumpRequested = false
                return
            }
            if jumpRequested || hum.get("Jump")?.asBool == true {
                leaveSeat(hum, jump: true)
                jumpRequested = false
                return
            }
            syncCharacterToSeat(character!, s)
            if s.className == "VehicleSeat" { stepVehicle(dt, seat: s) }
            jumpRequested = false
            return
        }
        let walkSpeed = hum.get("WalkSpeed")?.asFloat ?? 16
        var dir = Vector3.zero
        if controlsEnabled && (moveInput.x != 0 || moveInput.y != 0) {
            let f = Vector3(cameraCFrame.lookVector.x, 0, cameraCFrame.lookVector.z).unit
            let r = Vector3(cameraCFrame.rightVector.x, 0, cameraCFrame.rightVector.z).unit
            dir = r * moveInput.x + f * moveInput.y
            if dir.magnitude > 1 { dir = dir.unit }
            moveToTarget = nil
        } else if let sm = scriptMove, sm.until > rt.time {
            dir = Vector3(sm.dir.x, 0, sm.dir.z)
            if dir.magnitude > 1 { dir = dir.unit }
        } else if let target = moveToTarget {
            let pos = PartData.cframe(root).position
            let to = Vector3(target.x - pos.x, 0, target.z - pos.z)
            if to.magnitude < 1 {
                moveToTarget = nil
                rt.fire(hum, "MoveToFinished", [.bool(true)])
            } else { dir = to.unit }
        }
        lastMoveDir = dir

        let gravity = dm.workspace.get("Gravity")?.asFloat ?? 196.2
        let wantJump = jumpRequested || hum.get("Jump")?.asBool == true
        jumpRequested = false
        if hum.get("Jump")?.asBool == true { hum.set("Jump", .bool(false), notify: false) }
        if wantJump && grounded && hum.attributes["__state_Jumping"]?.asBool != false {
            let useJP = hum.get("UseJumpPower")?.asBool ?? true
            charVelocity.y = useJP ? (hum.get("JumpPower")?.asFloat ?? 50) : (2 * gravity * (hum.get("JumpHeight")?.asFloat ?? 7.2)).squareRoot()
            grounded = false
            rt.fire(hum, "Jumping", [.bool(true)])
            rt.fire(hum, "StateChanged", [stateItem(8), stateItem(3)])
        }
        charVelocity.x = dir.x * walkSpeed
        charVelocity.z = dir.z * walkSpeed
        if !grounded { charVelocity.y -= gravity * dt }

        var cf = PartData.cframe(root)
        let wasGrounded = grounded
        let (newPos, onGround, groundPart) = physics.moveCharacter(from: cf.position, velocity: charVelocity, dt: dt, ignore: character!)
        grounded = onGround
        if grounded && charVelocity.y < 0 { charVelocity.y = 0 }
        if !grounded && charVelocity.y > 0, newPos.y - cf.position.y < charVelocity.y * dt * 0.5 { charVelocity.y = 0 } // bumped head
        cf = cf.withPosition(newPos)
        if dir.magnitude > 0.01 && (hum.get("AutoRotate")?.asBool ?? true) {
            let target = CFrame.lookAt(newPos, newPos + Vector3(dir.x, 0, dir.z))
            cf = cf.lerp(target, min(1, dt * 12))
        }
        PartData.setCFrame(root, cf)
        hum.set("MoveDirection", .vector3(dir), notify: false)
        if grounded != wasGrounded {
            rt.fire(hum, "StateChanged", [stateItem(wasGrounded ? 8 : 5), stateItem(grounded ? 7 : 5)])
            if !grounded { rt.fire(hum, "FreeFalling", [.bool(true)]) }
        }
        rt.fire(hum, "Running", [.number(Double(dir.magnitude * walkSpeed))])
        if seat == nil && seatCooldown <= 0 {
            trySit(hum, rootCF: cf, groundPart: groundPart)
        }
    }

    private func stateItem(_ v: Int) -> ScriptValue { .object(.enumItem(ScriptEnums.item("HumanoidStateType", value: v) ?? ScriptEnums.item("HumanoidStateType", value: 8)!)) }

    private func syncCharacterToSeat(_ ch: Instance, _ s: Instance) {
        let targetCF = PartData.cframe(s) * CFrame.at(Vector3(0, PartData.size(s).y / 2 + 1.5, 0))
        if let root = rootPart {
            let delta = targetCF * PartData.cframe(root).inverse
            for p in ModelMath.parts(ch) { PartData.setCFrame(p, delta * PartData.cframe(p)) }
        } else {
            ModelMath.pivotTo(ch, targetCF)
        }
        physics.solveJoints(only: ch)
    }

    private func trySit(_ hum: Instance, rootCF: CFrame, groundPart: Instance?) {
        func canUse(_ s: Instance) -> Bool {
            (s.className == "Seat" || s.className == "VehicleSeat")
                && s.get("Disabled")?.asBool != true
                && s.get("Occupant")?.asInstance == nil
        }
        if let gp = groundPart, canUse(gp) {
            sit(hum, gp)
            return
        }
        let pos = rootCF.position
        let nearby = physics.query((pos - Vector3(1.25, 3.2, 1.25), pos + Vector3(1.25, 2.0, 1.25))).filter(canUse)
        if let closest = nearby.min(by: { (PartData.cframe($0).position - pos).magnitude < (PartData.cframe($1).position - pos).magnitude }) {
            sit(hum, closest)
        }
    }

    private func sit(_ hum: Instance, _ s: Instance) {
        seat = s
        s.set("Occupant", .ref(hum))
        hum.set("Sit", .bool(true))
        hum.set("SeatPart", .ref(s))
        if let ch = character { syncCharacterToSeat(ch, s) }
        rt.fire(hum, "Seated", [.bool(true), .object(.instance(s))])
    }

    private func leaveSeat(_ hum: Instance, jump: Bool = true) {
        guard let s = seat else { return }
        seat = nil
        seatCooldown = 1.0
        updateVirtualKeys(throttle: 0, steer: 0)
        if s.className == "VehicleSeat" {
            s.set("Throttle", .int(0))
            s.set("ThrottleFloat", .float(0))
            s.set("Steer", .int(0))
            s.set("SteerFloat", .float(0))
        }
        s.set("Occupant", .ref(nil))
        hum.set("Sit", .bool(false), notify: false)
        hum.set("SeatPart", .ref(nil), notify: false)
        hum.set("Jump", .bool(false), notify: false)
        if jump, let root = rootPart {
            let sCF = PartData.cframe(s)
            var exitPos = sCF.position + Vector3(0, PartData.size(s).y * 0.5 + 3.2, 0)
            if physics.raycastStatic(origin: sCF.position, direction: Vector3(0, 3.5, 0)) != nil {
                exitPos += sCF.rightVector * 3.5
            }
            PartData.setCFrame(root, sCF.rotationOnly.withPosition(exitPos))
            charVelocity.y = 35
            grounded = false
        }
        rt.fire(hum, "Seated", [.bool(false), .nil_])
    }

    private func updateVirtualKeys(throttle: Int32, steer: Int32) {
        var desired = Set<String>()
        if throttle > 0 { desired.insert("W") } else if throttle < 0 { desired.insert("S") }
        if steer < 0 { desired.insert("A") } else if steer > 0 { desired.insert("D") }
        for k in virtualKeys where !desired.contains(k) { fireInput(k, began: false) }
        for k in desired where !virtualKeys.contains(k) { fireInput(k, began: true) }
        virtualKeys = desired
    }

    private func hasActiveLinearMover(in body: PhysicsWorld.Body) -> Bool {
        let partSet = Set(body.parts.map(ObjectIdentifier.init))
        for m in physics.movers where m.parent != nil && m.get("Enabled")?.asBool != false {
            let host = m.parent.flatMap { $0.isA("BasePart") ? $0 : nil } ?? m.get("Attachment0")?.asInstance?.parent
            guard let host, partSet.contains(ObjectIdentifier(host)) else { continue }
            switch m.className {
            case "BodyVelocity":
                let mf = m.get("MaxForce")?.asVector3 ?? .zero
                let v = m.get("Velocity")?.asVector3 ?? .zero
                if (mf.x > 1 || mf.z > 1) && Vector3(v.x, 0, v.z).magnitude > 0.1 { return true }
            case "LinearVelocity":
                let mf = m.get("MaxForce")?.asFloat ?? 0
                let v = m.get("VectorVelocity")?.asVector3 ?? .zero
                let lv = abs(m.get("LineVelocity")?.asFloat ?? 0)
                if mf > 1 && (Vector3(v.x, 0, v.z).magnitude > 0.1 || lv > 0.1) { return true }
            case "BodyForce", "BodyThrust", "VectorForce":
                let f = m.get("Force")?.asVector3 ?? .zero
                if Vector3(f.x, 0, f.z).magnitude > 1 { return true }
            case "RocketPropulsion":
                if (m.get("MaxThrust")?.asFloat ?? 0) > 1 { return true }
            default: break
            }
        }
        return false
    }

    private func stepVehicle(_ dt: Float, seat s: Instance) {
        let throttleF: Float = controlsEnabled ? max(-1, min(1, moveInput.y)) : 0
        let steerF: Float = controlsEnabled ? max(-1, min(1, moveInput.x)) : 0
        let throttle: Int32 = throttleF > 0.15 ? 1 : (throttleF < -0.15 ? -1 : 0)
        let steer: Int32 = steerF > 0.15 ? 1 : (steerF < -0.15 ? -1 : 0)

        s.set("Throttle", .int(throttle))
        s.set("ThrottleFloat", .float(throttleF))
        s.set("Steer", .int(steer))
        s.set("SteerFloat", .float(steerF))
        updateVirtualKeys(throttle: throttle, steer: steer)

        guard let body = physics.body(of: s), !hasActiveLinearMover(in: body) else { return }

        var maxSpeed = max(8, s.get("MaxSpeed")?.asFloat ?? 25)
        let partSet = Set(body.parts.map(ObjectIdentifier.init))
        for d in dm.workspace.descendants() where d.className == "HingeConstraint" || d.className == "CylindricalConstraint" {
            guard d.get("ActuatorType")?.asEnum == 1,
                  (d.get("MotorMaxTorque")?.asFloat ?? 0) > 0 || (d.get("MotorMaxForce")?.asFloat ?? 0) > 0,
                  let p0 = d.get("Attachment0")?.asInstance?.parent,
                  let p1 = d.get("Attachment1")?.asInstance?.parent,
                  partSet.contains(ObjectIdentifier(p0)) || partSet.contains(ObjectIdentifier(p1)),
                  let av = d.get("AngularVelocity")?.asFloat, abs(av) > 0.5 else { continue }
            maxSpeed = max(maxSpeed, min(140, abs(av) * 1.6))
        }

        let torque = max(2, s.get("Torque")?.asFloat ?? 10)
        let turnSpeed = max(0.5, s.get("TurnSpeed")?.asFloat ?? 1)
        let look = PartData.cframe(s).lookVector
        var fwd = Vector3(look.x, 0, look.z)
        fwd = fwd.magnitude > 1e-4 ? fwd.unit : Vector3(0, 0, -1)
        let right = Vector3(-fwd.z, 0, fwd.x)

        var fwdSpeed = body.velocity.dot(fwd)
        var latSpeed = body.velocity.dot(right)
        if abs(throttleF) > 0.05 {
            let target = throttleF * (throttleF < 0 ? maxSpeed * 0.65 : maxSpeed)
            let reversing = (target > 0 && fwdSpeed < -0.5) || (target < 0 && fwdSpeed > 0.5)
            let accel = max(18, min(140, torque * 3.5)) * (reversing ? 1.6 : 1.0)
            let diff = target - fwdSpeed
            let stepDV = max(-accel * dt, min(accel * dt, diff))
            fwdSpeed += stepDV
        } else {
            fwdSpeed *= max(0, 1 - dt * 2.5)
            if abs(fwdSpeed) < 0.08 { fwdSpeed = 0 }
        }
        latSpeed *= max(0, 1 - dt * 10)
        let vy = body.velocity.y
        body.velocity = fwd * fwdSpeed + right * latSpeed
        body.velocity.y = vy

        if abs(steerF) > 0.05 && (abs(fwdSpeed) > 0.5 || abs(throttleF) > 0.05) {
            let dirSign: Float = fwdSpeed < -0.5 ? -1 : 1
            let speedScale = max(0.35, min(1.0, abs(fwdSpeed) / 10.0))
            let yawDelta = -steerF * dirSign * min(4.2, max(0.9, turnSpeed * 1.6)) * speedScale * dt
            physics.rotateBody(body, around: PartData.cframe(s).position, yawDelta: yawDelta)
        }
        body.driven = true
        if abs(throttleF) > 0.05 || abs(steerF) > 0.05 || abs(fwdSpeed) > 0.2 {
            body.asleep = false
            body.restTime = 0
        }
    }

    private func die() {
        guard let ch = character else { return }
        if let hum = humanoid, hum.get("BreakJointsOnDeath")?.asBool != false {
            for j in ch.descendants() where j.isA("JointInstance") { j.destroy() }
            physics.dirty = true
        }
        if let hum = humanoid { rt.fire(hum, "StateChanged", [stateItem(8), stateItem(15)]) }
        let respawn = dm.findService("Players")?.get("RespawnTime")?.asFloat ?? 5
        let auto = dm.findService("Players")?.get("CharacterAutoLoads")?.asBool ?? true
        deadTimer = auto ? respawn : nil
    }

    private func killFallen() {
        let limit = dm.workspace.get("FallenPartsDestroyHeight")?.asFloat ?? -500
        if let root = rootPart, PartData.cframe(root).position.y < limit, let hum = humanoid, (hum.get("Health_XML")?.asFloat ?? 100) > 0 {
            try? rt.api.setValue(hum, "Health", .number(0))
        }
        for b in physics.bodies where b.root.parent != nil && PartData.cframe(b.root).position.y < limit {
            var top: Instance = b.root
            while let p = top.parent, p !== dm.workspace, p.isA("Model") { top = p }
            if top !== character { top.destroy() }
        }
    }

    // MARK: touches (PlaySession.checkCharacterTouches / touchBegin / touchEnd)

    struct PairKey: Hashable { let a: ObjectIdentifier; let b: ObjectIdentifier }

    private func checkTouches() {
        var now = Set<PairKey>()
        var pairs: [(Instance, Instance)] = []
        let movers: [Instance] = (character?.descendants().filter { $0.isA("BasePart") } ?? []) + physics.bodies.flatMap { $0.parts }
        for a in movers where a.get("CanTouch")?.asBool != false {
            for b in physics.query(Geometry.aabb(a), expand: 0.1) where b !== a && b.get("CanTouch")?.asBool != false {
                if let ch = character, a.isDescendant(of: ch) && b.isDescendant(of: ch) { continue }
                guard Geometry.obbOverlap(PartData.cframe(a), PartData.size(a) * 0.5 + Vector3(0.05, 0.05, 0.05),
                                          PartData.cframe(b), PartData.size(b) * 0.5) else { continue }
                let k = PairKey(a: ObjectIdentifier(a), b: ObjectIdentifier(b))
                let k2 = PairKey(a: ObjectIdentifier(b), b: ObjectIdentifier(a))
                if now.contains(k) || now.contains(k2) { continue }
                now.insert(k)
                if !touching.contains(k) && !touching.contains(k2) { pairs.append((a, b)) }
            }
        }
        for (a, b) in pairs {
            rt.fire(b, "Touched", [.object(.instance(a))])
            rt.fire(a, "Touched", [.object(.instance(b))])
        }
        for k in touching where !now.contains(k) && !now.contains(PairKey(a: k.b, b: k.a)) {
            if let a = physics.part(k.a), let b = physics.part(k.b) {
                rt.fire(b, "TouchEnded", [.object(.instance(a))])
                rt.fire(a, "TouchEnded", [.object(.instance(b))])
            }
        }
        touching = now
    }

    public func touchingParts(_ part: Instance) -> [Instance] {
        let k = ObjectIdentifier(part)
        return touching.compactMap { p in p.a == k ? physics.part(p.b) : (p.b == k ? physics.part(p.a) : nil) }
    }

    // MARK: camera (PlaySession.updateCamera)

    private func updateCamera(_ dt: Float) {
        guard let cam = dm.workspace.get("CurrentCamera")?.asInstance else { return }
        let camType = cam.get("CameraType")?.asEnum ?? 0
        if camType == 6 { // Scriptable
            cameraCFrame = cam.get("CFrame")?.asCFrame ?? cameraCFrame
            fieldOfView = cam.get("FieldOfView")?.asFloat ?? 70
            return
        }
        let subject = cam.get("CameraSubject")?.asInstance
        var focus: Vector3
        if let s = subject, s.isA("BasePart") {
            focus = PartData.cframe(s).position
        } else if let head = character?.findFirstChild("Head") ?? rootPart {
            focus = PartData.cframe(head).position + Vector3(0, 0.5, 0)
        } else {
            focus = cameraCFrame.position + cameraCFrame.lookVector * camDistance
        }
        if let hum = humanoid, let off = hum.get("CameraOffset")?.asVector3 { focus += off }
        if let s = seatedVehicle, rt.time - lastCamDrag > 1.2, vehicleSpeed > 2 {
            let look = PartData.cframe(s).lookVector
            if Vector3(look.x, 0, look.z).magnitude > 0.1 {
                let targetYaw = atan2(-look.x, -look.z)
                var diff = (targetYaw - camYaw).truncatingRemainder(dividingBy: 2 * .pi)
                if diff > .pi { diff -= 2 * .pi } else if diff < -.pi { diff += 2 * .pi }
                camYaw += diff * (1 - exp(-dt * 2.5))
            }
        }
        let rot = CFrame.ry(camYaw) * CFrame.rx(camPitch)
        var dist = camDistance
        let back = rot.backVector
        if dist > 0.6, let hit = physics.raycastStatic(origin: focus, direction: back * dist) {
            dist = max(0.5, hit.t * dist - 0.4)
        }
        cameraCFrame = rot.withPosition(focus + back * dist)
        fieldOfView = cam.get("FieldOfView")?.asFloat ?? 70
        cam.set("CFrame", .cframe(cameraCFrame), notify: false)
        cam.set("Focus", .cframe(.at(focus)), notify: false)
        if shiftLock, seat == nil, let root = rootPart {
            let p = PartData.cframe(root).position
            PartData.setCFrame(root, CFrame.lookAt(p, p + Vector3(cameraCFrame.lookVector.x, 0, cameraCFrame.lookVector.z)))
        }
    }

    public func cameraDrag(dx: Float, dy: Float) {
        lastCamDrag = rt.time
        camYaw -= dx * 0.008
        camPitch = max(-1.4, min(1.4, camPitch - dy * 0.008))
    }

    public func cameraZoom(_ factor: Float) {
        let minZ = player?.get("CameraMinZoomDistance")?.asFloat ?? 0.5
        let maxZ = player?.get("CameraMaxZoomDistance")?.asFloat ?? 128
        camDistance = max(minZ, min(maxZ, camDistance / factor))
    }

    public var isFirstPerson: Bool { camDistance < 1 }

    // MARK: animation (PlaySession.animate: default Animate clips, script tracks, procedural fallback)

    private func animate(_ dt: Float) {
        guard let ch = character else { return }
        let speed = Vector3(charVelocity.x, 0, charVelocity.z).magnitude
        let hum = humanoid
        let pose: String = (hum?.get("Health_XML")?.asFloat ?? 100) <= 0 ? "dead" : seat != nil ? "sit" : !grounded ? (charVelocity.y > 0 ? "jump" : "fall") : speed > 0.5 ? "walk" : "idle"
        animTime += dt * (pose == "walk" ? max(1, speed / 16) : 1)
        let r15 = ch.findFirstChild("UpperTorso") != nil

        // Default animations driven by the builtin Animate tree (skipped if user disabled/replaced Animate).
        let cfg = DefaultAnimate.config(of: ch)
        if let cfg {
            if pose != "idle" { animPlayer.stopTag("emote", fade: 0.15); pendingEmote = nil }
            if let pe = pendingEmote, let clip = animLib.clip(pe.id) {
                pendingEmote = nil
                let t = animPlayer.play(clip, tag: "emote", fade: 0.15, priority: 2)
                t.looped = DefaultAnimate.loopingEmotes.contains(pe.key)
            }
            if pose != defaultPose {
                animPlayer.stopTag("default", fade: 0.2)
                animPlayer.stopTag("defaultRun", fade: 0.2)
                defaultPose = pose
            }
            if pose == "walk" && r15 {
                let runBlend = min(1, max(0, (speed - 6.4) / 6.4))
                let walkWeight = max(0.01, 1 - runBlend)
                let runWeight = max(0.01, runBlend)
                let rate = max(0.5, speed / 14.5)
                if !animPlayer.isPlaying("default"),
                   let id = DefaultAnimate.pick(cfg["walk"]),
                   let clip = animLib.clip(id) {
                    let t = animPlayer.play(clip, tag: "default", fade: 0.2, weight: walkWeight, speed: rate, priority: 0)
                    t.looped = true
                }
                if !animPlayer.isPlaying("defaultRun"),
                   let id = DefaultAnimate.pick(cfg["run"]),
                   let clip = animLib.clip(id) {
                    let t = animPlayer.play(clip, tag: "defaultRun", fade: 0.2, weight: runWeight, speed: rate, priority: 0)
                    t.looped = true
                }
                for tr in animPlayer.tracks where !tr.stopping {
                    if tr.tag == "default" { tr.targetWeight = walkWeight; tr.speed = rate }
                    else if tr.tag == "defaultRun" { tr.targetWeight = runWeight; tr.speed = rate }
                }
            } else if !animPlayer.isPlaying("default"), pose != "dead",
                      let id = DefaultAnimate.pick(cfg[pose]),
                      let clip = animLib.clip(id) {
                let t = animPlayer.play(clip, tag: "default", fade: 0.2, speed: pose == "walk" ? max(0.5, speed / 16) : 1, priority: 0)
                t.looped = pose != "jump"
            }
            let hasTool = ch.children.contains { $0.className == "Tool" }
            if hasTool && pose != "dead" {
                if !animPlayer.isPlaying("tool"),
                   let id = DefaultAnimate.pick(cfg["toolnone"]),
                   let clip = animLib.clip(id) {
                    let t = animPlayer.play(clip, tag: "tool", fade: 0.1, priority: 1)
                    t.looped = true
                }
            } else {
                animPlayer.stopTag("tool", fade: 0.1)
            }
        } else {
            animPlayer.stopTag("default", fade: 0.1)
            animPlayer.stopTag("defaultRun", fade: 0.1)
            animPlayer.stopTag("tool", fade: 0.1)
            animPlayer.stopTag("emote", fade: 0.1)
            defaultPose = ""
        }

        // Script tracks waiting for their clip to download.
        for t in tracks where t.isPlaying && t.payload == nil {
            if let id = t.animation.get("AnimationId")?.description, let clip = animLib.clip(id) { attach(t, clip) }
        }
        for done in animPlayer.step(dt) {
            if let ref = done.ref, ref.isPlaying { ref.isPlaying = false; rt.fire(ref, "Stopped"); rt.fire(ref, "Ended") }
        }
        for t in tracks where t.isPlaying { if let tr = t.payload as? AnimPlayer.Track { t.timePosition = tr.time } }

        // Apply to every Motor6D: animation first, procedural motion as a fallback for R6.
        var animated = false
        for m in ch.descendants() where m.className == "Motor6D" {
            guard let p1 = m.get("Part1")?.asInstance else { continue }
            if let cf = animPlayer.transform(p1.name) {
                m.set("Transform", .cframe(cf), notify: false)
                animated = true
            }
        }
        if !animated, cfg != nil, r15 {
            func joint(_ part: String, _ angle: Float) {
                ch.findFirstChild(part)?.children.first { $0.className == "Motor6D" }?.set("Transform", .cframe(CFrame.rx(angle)), notify: false)
            }
            var arm: Float = 0, leg: Float = 0
            switch pose {
            case "walk": arm = sin(animTime * 9) * 0.9; leg = arm
            case "jump", "fall": arm = .pi * 0.9; leg = 0
            case "sit": arm = 0.4; leg = .pi / 2
            default: arm = sin(animTime * 1.5) * 0.05
            }
            joint("RightUpperArm", -arm); joint("LeftUpperArm", pose == "jump" || pose == "fall" ? -arm : arm)
            joint("RightUpperLeg", pose == "sit" ? leg : leg); joint("LeftUpperLeg", pose == "sit" ? leg : -leg)
        }
        if !animated, cfg != nil, !r15, let torso = ch.findFirstChild("Torso") {
            func setMotor(_ name: String, _ angle: Float) {
                torso.findFirstChild(name)?.set("Transform", .cframe(CFrame.rz(angle)), notify: false)
            }
            switch pose {
            case "walk":
                let a = sin(animTime * 9) * 1.0
                setMotor("Right Shoulder", a); setMotor("Left Shoulder", a)
                setMotor("Right Hip", -a); setMotor("Left Hip", -a)
            case "jump", "fall":
                setMotor("Right Shoulder", .pi); setMotor("Left Shoulder", -.pi)
                setMotor("Right Hip", 0); setMotor("Left Hip", 0)
            case "sit":
                setMotor("Right Shoulder", .pi / 2); setMotor("Left Shoulder", -.pi / 2)
                setMotor("Right Hip", .pi / 2); setMotor("Left Hip", -.pi / 2)
            default:
                let b = sin(animTime * 1.5) * 0.05
                setMotor("Right Shoulder", b); setMotor("Left Shoulder", -b)
                setMotor("Right Hip", 0); setMotor("Left Hip", 0)
            }
        }
        physics.solveJoints(only: ch)
    }

    private func attach(_ t: AnimTrackRef, _ clip: AnimClip) {
        let tr = animPlayer.play(clip, tag: "script", fade: 0.1, weight: t.weight, speed: t.speed, priority: max(t.priority, 1))
        tr.looped = t.looped || clip.looped
        tr.ref = t
        t.payload = tr
        t.length = clip.length
    }

    // MARK: prompts & clicks

    private func updatePrompts() {
        guard let root = rootPart else { nearestPrompt = nil; return }
        let pos = PartData.cframe(root).position
        var best: (Instance, Float)?
        for p in dm.workspace.descendants() where p.className == "ProximityPrompt" && p.get("Enabled")?.asBool != false {
            guard let host = p.parent, let at = host.isA("BasePart") ? PartData.cframe(host).position : (host.className == "Attachment" ? host.parent.map { PartData.cframe($0) * (host.get("CFrame")?.asCFrame ?? .identity) }?.position : nil) else { continue }
            let d = (at - pos).magnitude
            if d <= (p.get("MaxActivationDistance")?.asFloat ?? 10), d < (best?.1 ?? .greatestFiniteMagnitude) { best = (p, d) }
        }
        if best?.0 !== nearestPrompt {
            if let old = nearestPrompt { rt.fire(old, "PromptHidden") }
            nearestPrompt = best?.0
            if let n = nearestPrompt { rt.fire(n, "PromptShown", [.object(.enumItem(EnumItem(enumType: "ProximityPromptInputType", name: "Touch", value: 2)))]) }
        }
    }

    public func triggerPrompt() {
        guard let p = nearestPrompt, let pl = player else { return }
        rt.fire(p, "Triggered", [.object(.instance(pl))])
        if let svc = dm.findService("ProximityPromptService") { rt.fire(svc, "PromptTriggered", [.object(.instance(p)), .object(.instance(pl))]) }
        rt.fire(p, "TriggerEnded", [.object(.instance(pl))])
    }

    public func requestJump() { jumpRequested = true; fireInput("Space", began: true); fireInput("Space", began: false)
        if let uis = dm.findService("UserInputService") { rt.fire(uis, "JumpRequest") }
    }

    private func fireInput(_ key: String, began: Bool) {
        guard let uis = dm.findService("UserInputService") else { return }
        let input: ScriptValue = .table([
            (.string("KeyCode"), .object(.enumItem(ScriptEnums.item("KeyCode", key) ?? ScriptEnums.item("KeyCode", "Unknown")!))),
            (.string("UserInputType"), .object(.enumItem(ScriptEnums.item("UserInputType", "Keyboard")!))),
            (.string("UserInputState"), .object(.enumItem(ScriptEnums.item("UserInputState", began ? "Begin" : "End")!))),
            (.string("Position"), .object(.vector3(.zero))), (.string("Delta"), .object(.vector3(.zero))),
        ])
        rt.fire(uis, began ? "InputBegan" : "InputEnded", [input, .bool(false)])
    }

    /// A tap in the 3D view: ClickDetectors, tools, mouse and touch events.
    public func tap(x: Float, y: Float) {
        let ray = cameraRay(x: x, y: y)
        let hit = physics.raycastAll(origin: ray.origin, direction: ray.direction.unit * 1000, ignore: character)
        if let p = player, let mouse = p.findFirstChildOfClass("PlayerMouse") {
            mouse.set("Hit", .cframe(.at(hit?.point ?? ray.origin + ray.direction.unit * 1000)), notify: false)
            mouse.set("Target", .ref(hit?.part), notify: false)
            mouse.set("X", .double(Double(x)), notify: false)
            mouse.set("Y", .double(Double(y)), notify: false)
            mouse.set("UnitRay", .ray(Ray(ray.origin, ray.direction.unit)), notify: false)
            rt.fire(mouse, "Button1Down"); rt.fire(mouse, "Button1Up")
        }
        if let uis = dm.findService("UserInputService") {
            let input: ScriptValue = .table([
                (.string("UserInputType"), .object(.enumItem(ScriptEnums.item("UserInputType", "Touch")!))),
                (.string("UserInputState"), .object(.enumItem(ScriptEnums.item("UserInputState", "Begin")!))),
                (.string("Position"), .object(.vector3(Vector3(x, y, 0)))),
                (.string("KeyCode"), .object(.enumItem(ScriptEnums.item("KeyCode", "Unknown")!))),
            ])
            rt.fire(uis, "InputBegan", [input, .bool(false)])
            rt.fire(uis, "TouchTap", [.table([(.number(1), .object(.vector2(Vector2(x, y))))]), .bool(false)])
            rt.fire(uis, "InputEnded", [input, .bool(false)])
            if let hit { rt.fire(uis, "TouchTapInWorld", [.object(.vector2(Vector2(x, y))), .bool(false)]); _ = hit }
        }
        if let tool = character?.children.first(where: { $0.className == "Tool" }) { rt.fire(tool, "Activated") }
        if let part = hit?.part {
            var node: Instance? = part
            while let n = node {
                if let cd = n.children.first(where: { $0.className == "ClickDetector" }), let p = player {
                    let maxD = cd.get("MaxActivationDistance")?.asFloat ?? 32
                    if let root = rootPart, (PartData.cframe(root).position - hit!.point).magnitude > maxD { break }
                    rt.fire(cd, "MouseClick", [.object(.instance(p))])
                    break
                }
                node = n.parent
                if node === dm.workspace { break }
            }
        }
    }

    // MARK: GUI (ui/GuiOverlay.kt input handling)

    public func layoutGui() -> [GuiItem] {
        GuiLayout.layout(playerGui: player?.findFirstChild("PlayerGui"), workspace: dm.workspace, viewport: viewport) { [unowned self] p in
            self.worldToViewport(p)
        }
    }

    public func guiPress(_ g: Instance, down: Bool) {
        let input: ScriptValue = .table([
            (.string("UserInputType"), .object(.enumItem(ScriptEnums.item("UserInputType", "Touch")!))),
            (.string("UserInputState"), .object(.enumItem(ScriptEnums.item("UserInputState", down ? "Begin" : "End")!))),
        ])
        rt.fire(g, down ? "MouseButton1Down" : "MouseButton1Up", [.number(0), .number(0)])
        rt.fire(g, down ? "InputBegan" : "InputEnded", [input])
    }

    public func guiActivate(_ g: Instance) {
        rt.fire(g, "MouseButton1Click")
        rt.fire(g, "Activated", [.table([]), .number(1)])
    }

    public func guiText(_ g: Instance, _ text: String, enter: Bool) {
        g.set("Text", .string(text))
        if enter { rt.fire(g, "FocusLost", [.bool(true), .nil_]) }
    }

    public func guiFocus(_ g: Instance) { rt.fire(g, "Focused") }

    public func guiScroll(_ g: Instance, dx: Float, dy: Float) {
        var cp = Vector2.zero
        if case .vector2(let v)? = g.get("CanvasPosition") { cp = v }
        let r = Gui.abs(g)
        let canvas: UDim2 = { if case .udim2(let u)? = g.get("CanvasSize") { return u }; return UDim2(0, 0, 2, 0) }()
        let maxY = max(0, canvas.y.scale * r.h + Float(canvas.y.offset) - r.h)
        let maxX = max(0, canvas.x.scale * r.w + Float(canvas.x.offset) - r.w)
        cp = Vector2(max(0, min(maxX, cp.x + dx)), max(0, min(maxY, cp.y + dy)))
        g.set("CanvasPosition", .vector2(cp))
    }

    // MARK: tools & chat

    public func backpackTools() -> [Instance] {
        (player?.findFirstChild("Backpack")?.children.filter { $0.className == "Tool" } ?? []) +
            (character?.children.filter { $0.className == "Tool" } ?? [])
    }

    public func equipTool(_ hum: Instance, _ tool: Instance) {
        guard let ch = hum.parent else { return }
        unequipTools(hum)
        try? tool.setParent(ch)
        if let handle = tool.findFirstChild("Handle"), handle.isA("BasePart"), let arm = ch.findFirstChild("Right Arm") ?? ch.findFirstChild("RightHand") {
            let grip = tool.get("Grip")?.asCFrame ?? .identity
            let c0 = CFrame.at(Vector3(0, -1, 0)) * CFrame.rx(-.pi / 2)
            PartData.setCFrame(handle, PartData.cframe(arm) * c0 * grip.inverse)
            let w = InstanceFactory.create("Weld")
            w.name = "RightGrip"
            w.archivable = false
            w.set("Part0", .ref(arm), notify: false)
            w.set("Part1", .ref(handle), notify: false)
            w.set("C0", .cframe(c0), notify: false)
            w.set("C1", .cframe(grip), notify: false)
            try? w.setParent(arm)
        }
        physics.dirty = true
        rt.fire(tool, "Equipped", [player?.findFirstChildOfClass("PlayerMouse").map { .object(.instance($0)) } ?? .nil_])
    }

    public func unequipTools(_ hum: Instance) {
        guard let ch = hum.parent, let pack = player?.findFirstChild("Backpack") else { return }
        for t in ch.children where t.className == "Tool" {
            ch.descendants().first { $0.name == "RightGrip" }?.destroy()
            try? t.setParent(pack)
            rt.fire(t, "Unequipped")
        }
        physics.dirty = true
    }

    public func toggleTool(_ tool: Instance) {
        guard let hum = humanoid else { return }
        if tool.parent === character { unequipTools(hum) } else { equipTool(hum, tool) }
    }

    public func chat(_ from: Instance?, _ text: String) {
        let name = from?.name ?? "System"
        chatLines.append((name, text))
        if chatLines.count > 50 { chatLines.removeFirst() }
        if let p = from { rt.fire(p, "Chatted", [.string(text)]) }
    }

    /// Play one of Roblox's default emotes (`wave`, `point`, `cheer`, `laugh`, `dance`, `dance2`, `dance3`).
    public func playEmote(_ name: String) {
        guard let ch = character, let cfg = DefaultAnimate.config(of: ch) else { return }
        let key = name.lowercased()
        guard let id = DefaultAnimate.pick(cfg[key]) else { return }
        animPlayer.stopTag("emote", fade: 0.1)
        if let clip = animLib.clip(id) {
            pendingEmote = nil
            let t = animPlayer.play(clip, tag: "emote", fade: 0.15, priority: 2)
            t.looped = DefaultAnimate.loopingEmotes.contains(key)
        } else {
            pendingEmote = (key, id)
        }
    }

    public func sendChat(_ text: String) {
        guard let p = player else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/e ") || trimmed.hasPrefix("/emote ") {
            let emote = trimmed.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
            if !emote.isEmpty { playEmote(emote) }
            return
        }
        if trimmed.hasPrefix("/") { return }
        chat(p, trimmed)
        if let ch = dm.findService("TextChatService")?.findFirstChild("TextChannels")?.findFirstChild("RBXGeneral") {
            rt.fire(ch, "MessageReceived", [.table([(.string("Text"), .string(trimmed)),
                                                    (.string("TextSource"), .table([(.string("Name"), .string(p.name)), (.string("UserId"), .number(1))]))])])
        }
    }

    public func leaderstats() -> [(String, String)] {
        guard let ls = player?.findFirstChild("leaderstats") else { return [] }
        return ls.children.filter { $0.isA("ValueBase") }.map { ($0.name, $0.get("Value")?.description ?? "") }
    }

    public func bindAction(_ name: String, _ fn: LuaRef, touchButton: Bool, keys: [String]) {
        if touchButton { actions[name] = (name, fn) }
    }
    public func unbindAction(_ name: String) { actions[name] = nil }
    public func setActionTitle(_ name: String, _ title: String) { if let a = actions[name] { actions[name] = (title, a.fn) } }
    public func pressAction(_ name: String, began: Bool) {
        guard let a = actions[name] else { return }
        let state = ScriptEnums.item("UserInputState", began ? "Begin" : "End")!
        let input: ScriptValue = .table([(.string("UserInputState"), .object(.enumItem(state))),
                                         (.string("UserInputType"), .object(.enumItem(ScriptEnums.item("UserInputType", "Touch")!)))])
        rt.spawn(a.fn) { [unowned self] L in
            self.rt.pushValue(L, .string(name)); self.rt.pushValue(L, .object(.enumItem(state))); self.rt.pushValue(L, input)
            return 3
        }
    }

    // MARK: ScriptHost

    public func raycast(origin: Vector3, direction: Vector3, params: RaycastParamsV?) -> RaycastResultV? {
        let hit = physics.raycastAll(origin: origin, direction: direction, ignore: nil) { p in
            p.get("CanQuery")?.asBool != false && (params?.accepts(p) ?? true) &&
                (params?.respectCanCollide != true || p.get("CanCollide")?.asBool != false)
        }
        guard let hit else { return nil }
        return RaycastResultV(instance: hit.part, position: hit.point, normal: hit.normal, distance: direction.magnitude * hit.t,
                              material: PartData.material(hit.part))
    }
    public func velocity(of part: Instance) -> Vector3 {
        if let ch = character, part.isDescendant(of: ch) { return charVelocity }
        return physics.body(of: part)?.velocity ?? .zero
    }
    public func setVelocity(of part: Instance, _ v: Vector3) {
        if let ch = character, part.isDescendant(of: ch) { charVelocity = v; if v.y > 0 { grounded = false }; return }
        physics.body(of: part)?.velocity = v
        physics.body(of: part)?.asleep = false
    }
    public func angularVelocity(of part: Instance) -> Vector3 {
        physics.body(of: part)?.angularVelocity ?? part.get("RotVelocity")?.asVector3 ?? .zero
    }
    public func setAngularVelocity(of part: Instance, _ v: Vector3) {
        if let b = physics.body(of: part) { b.angularVelocity = v; b.asleep = false }
        part.set("RotVelocity", .vector3(v), notify: false)
    }
    public func assemblyRoot(of part: Instance) -> Instance {
        physics.body(of: part)?.root ?? part
    }
    public func assemblyMass(of part: Instance) -> Float {
        physics.body(of: part)?.mass ?? Physics.mass(part)
    }
    public func applyImpulse(_ part: Instance, _ impulse: Vector3) {
        if let ch = character, part.isDescendant(of: ch) { charVelocity += impulse / 10; grounded = false; return }
        guard let b = physics.body(of: part) else { return }
        b.velocity += impulse / max(b.mass, 0.01)
        b.asleep = false
    }
    public func sit(_ seatPart: Instance, _ hum: Instance) {
        guard hum === humanoid,
              seatPart.get("Disabled")?.asBool != true else { return }
        let occ = seatPart.get("Occupant")?.asInstance
        if occ != nil && occ !== hum { return }
        if seat === seatPart { return }
        if seat != nil { leaveSeat(hum, jump: false) }
        sit(hum, seatPart)
    }
    public func humanoidMove(_ humanoid: Instance, direction: Vector3) {
        guard humanoid === self.humanoid else { return }
        scriptMove = direction.magnitude < 1e-3 ? nil : (direction, rt.time + 0.2)
    }
    public func humanoidMoveTo(_ humanoid: Instance, target: Vector3) {
        guard humanoid === self.humanoid else { return }
        moveToTarget = target
    }
    public func humanoidJump(_ humanoid: Instance) { if humanoid === self.humanoid { jumpRequested = true } }
    public func moveDirection(_ humanoid: Instance) -> Vector3 { humanoid === self.humanoid ? lastMoveDir : .zero }
    public func isGrounded(_ humanoid: Instance) -> Bool { humanoid === self.humanoid ? grounded : true }

    public func loadTrack(owner: Instance, animation: Instance) -> AnimTrackRef? {
        let t = AnimTrackRef(owner: owner, animation: animation)
        if let id = animation.get("AnimationId")?.description, let clip = animLib.clip(id) {
            t.length = clip.length; t.looped = clip.looped; t.priority = clip.priority
        }
        tracks.removeAll { !$0.isPlaying && $0.payload == nil && $0.owner.parent == nil }
        tracks.append(t)
        return t
    }
    public func playTrack(_ t: AnimTrackRef, fade: Float, weight: Float, speed: Float) {
        if let old = t.payload as? AnimPlayer.Track { animPlayer.stop(old, fade: fade) }
        t.payload = nil
        t.isPlaying = true; t.weight = weight; t.speed = speed; t.timePosition = 0
        if let id = t.animation.get("AnimationId")?.description, let clip = animLib.clip(id) { attach(t, clip) }
        let animator = t.owner.findFirstChildOfClass("Animator") ?? t.owner
        rt.fire(animator, "AnimationPlayed", [.object(.track(t))])
    }
    public func stopTrack(_ t: AnimTrackRef, fade: Float) {
        guard t.isPlaying else { return }
        t.isPlaying = false
        if let tr = t.payload as? AnimPlayer.Track { animPlayer.stop(tr, fade: fade) }
        t.payload = nil
        rt.fire(t, "Stopped")
    }
    public func adjustTrack(_ t: AnimTrackRef, speed: Float?, weight: Float?, looped: Bool?, time: Float?) {
        let tr = t.payload as? AnimPlayer.Track
        if let speed { t.speed = speed; tr?.speed = speed }
        if let weight { t.weight = weight; tr?.targetWeight = weight; tr?.fadeRate = 10 }
        if let looped { t.looped = looped; tr?.looped = looped }
        if let time { t.timePosition = time; tr?.time = time }
    }
    public func playingTracks(_ owner: Instance) -> [AnimTrackRef] { tracks.filter { $0.isPlaying && $0.owner === owner } }
    public func playSound(_ sound: Instance) { onSound(sound, true) }
    public func stopSound(_ sound: Instance) { onSound(sound, false) }
    public func viewportSize() -> Vector2 { viewport }

    public func cameraRay(x: Float, y: Float) -> Ray {
        let t = tan(fieldOfView * .pi / 360), aspect = viewport.x / max(viewport.y, 1)
        let nx = x / viewport.x * 2 - 1, ny = 1 - y / viewport.y * 2
        let d = (cameraCFrame.lookVector + cameraCFrame.rightVector * (nx * t * aspect) + cameraCFrame.upVector * (ny * t)).unit
        return Ray(cameraCFrame.position, d)
    }
    public func worldToViewport(_ p: Vector3) -> (Vector3, Bool) {
        let l = cameraCFrame.pointToObject(p)
        let t = tan(fieldOfView * .pi / 360), aspect = viewport.x / max(viewport.y, 1)
        let depth = -l.z
        guard depth > 0.01 else { return (Vector3(0, 0, depth), false) }
        let nx = l.x / (depth * t * aspect), ny = l.y / (depth * t)
        let sx = (nx + 1) / 2 * viewport.x, sy = (1 - ny) / 2 * viewport.y
        return (Vector3(sx, sy, depth), abs(nx) <= 1 && abs(ny) <= 1)
    }
    public func keyDown(_ key: String) -> Bool { virtualKeys.contains(key) }
    public func respawn(_ player: Instance) { if player === self.player { spawnCharacter() } }
}
