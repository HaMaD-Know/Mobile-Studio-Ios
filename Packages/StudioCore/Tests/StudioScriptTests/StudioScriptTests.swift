import XCTest
import StudioCore
@testable import StudioScript

final class StudioScriptTests: XCTestCase {
    /// Run `source` as a Script in Workspace and collect Output lines.
    private func run(_ source: String, steps: Int = 0, dt: Double = 0.05) -> (ScriptRuntime, [String]) {
        let dm = PlaceFactory.newPlace(.baseplate)
        let rt = ScriptRuntime(dm: dm, isPlay: true)
        var out: [String] = []
        rt.onOutput = { level, s in out.append((level == .error ? "ERR " : level == .warn ? "WARN " : "") + s) }
        let s = InstanceFactory.create("Script")
        s.set("Source", .string(source))
        s.attachRaw(dm.workspace)
        rt.runScript(s)
        for _ in 0..<steps { rt.step(dt) }
        return (rt, out)
    }

    func testPrintAndMath() {
        let (_, out) = run("print('hi', 1 + 2, Vector3.new(1, 2, 3).Magnitude > 3)")
        XCTAssertEqual(out, ["hi 3 true"])
    }

    func testLuauSyntax() {
        let (_, out) = run("""
        local x: number = 1
        x += 2
        for i = 1, 3 do if i == 2 then continue end x += i end
        print(`value {x}`)
        """)
        XCTAssertEqual(out, ["value 7"])
    }

    func testInstancesAndProperties() {
        let (rt, out) = run("""
        local p = Instance.new("Part")
        p.Name = "Box"
        p.Size = Vector3.new(4, 2, 1)
        p.Position = Vector3.new(0, 10, 0)
        p.Anchored = true
        p.Color = Color3.fromRGB(255, 0, 0)
        p.Parent = workspace
        print(workspace:FindFirstChild("Box").Size, p.Position.Y, p.BrickColor.Name ~= nil, p:IsA("BasePart"))
        print(typeof(p), typeof(p.CFrame), p.Material == Enum.Material.Plastic)
        """)
        XCTAssertEqual(out.first, "4, 2, 1 10 true true")
        XCTAssertEqual(out.last, "Instance CFrame true")
        XCTAssertNotNil(rt.dm.workspace.findFirstChild("Box"))
    }

    func testWaitAndTask() {
        let (_, out) = run("""
        task.spawn(function() print("spawned") end)
        task.delay(0.1, function() print("delayed") end)
        print("before")
        task.wait(0.2)
        print("after")
        """, steps: 10)
        XCTAssertEqual(out, ["spawned", "before", "delayed", "after"])
    }

    func testSignalsAndBindables() {
        let (_, out) = run("""
        local ev = Instance.new("BindableEvent")
        ev.Event:Connect(function(a, b) print("got", a, b) end)
        ev:Fire(1, "two")
        local fn = Instance.new("BindableFunction")
        fn.OnInvoke = function(x) return x * 2 end
        print("invoke", fn:Invoke(21))
        local v = Instance.new("IntValue")
        v.Changed:Connect(function(n) print("changed", n) end)
        v.Value = 5
        """)
        XCTAssertEqual(out, ["got 1 two", "invoke 42", "changed 5"])
    }

    func testModulesAndErrors() {
        let dm = PlaceFactory.newPlace(.empty)
        let rt = ScriptRuntime(dm: dm, isPlay: true)
        var out: [String] = []
        rt.onOutput = { _, s in out.append(s) }
        let m = InstanceFactory.create("ModuleScript")
        m.name = "Lib"
        m.set("Source", .string("return { add = function(a, b) return a + b end }"))
        m.attachRaw(dm.getService("ReplicatedStorage"))
        let s = InstanceFactory.create("Script")
        s.set("Source", .string("""
        local lib = require(game.ReplicatedStorage.Lib)
        print(lib.add(2, 3), require(game.ReplicatedStorage.Lib) == lib)
        local ok, err = pcall(function() error("boom") end)
        print(ok, string.find(err, "boom") ~= nil)
        workspace.NoSuchThing.Name = "x"
        """))
        s.attachRaw(dm.workspace)
        rt.runScript(s)
        XCTAssertEqual(out[0], "5 true")
        XCTAssertEqual(out[1], "false true")
        XCTAssertTrue(out.contains { $0.contains("attempt to index nil") }, "\(out)")
    }

    func testTweenService() {
        let (rt, _) = run("""
        local p = Instance.new("Part", workspace)
        p.Name = "T"
        p.Anchored = true
        local tw = game:GetService("TweenService"):Create(p, TweenInfo.new(0.5, Enum.EasingStyle.Linear), {Position = Vector3.new(10, 0, 0)})
        tw:Play()
        """, steps: 20)
        let p = rt.dm.workspace.findFirstChild("T")!
        XCTAssertEqual(PartData.cframe(p).position.x, 10, accuracy: 0.01)
    }

    func testInfiniteLoopTimesOut() {
        let (_, out) = run("while true do end")
        XCTAssertTrue(out.contains { $0.contains("timeout") }, "\(out)")
    }

    func testPlaySessionSpawnsCharacter() {
        let edit = PlaceFactory.newPlace(.baseplate)
        let s = InstanceFactory.create("Script")
        s.set("Source", .string("game.Players.PlayerAdded:Connect(function(p) p.CharacterAdded:Connect(function(c) print('char', c.Name) end) end)"))
        s.attachRaw(edit.getService("ServerScriptService"))
        let play = PlaySession(editModel: edit)
        var out: [String] = []
        play.onOutput = { _, line in out.append(line) }
        play.start()
        for _ in 0..<30 { play.step(1 / 30) }
        XCTAssertTrue(out.contains("char Player1"), "\(out)")
        let root = play.character!.findFirstChild("HumanoidRootPart")!
        // Standing on the spawn: root 3 studs above the spawn's top (spawn top at y = 1).
        XCTAssertEqual(PartData.cframe(root).position.y, 4, accuracy: 0.6)
        play.stop()
    }

    func testRigAndCustomCharacter() {
        let r6 = CharacterBuilder.buildR6(name: "Rig")
        CharacterBuilder.addR6Attachments(r6)
        XCTAssertNotNil(r6.findFirstChild("Head")?.findFirstChild("HatAttachment"))
        let r15 = CharacterBuilder.buildR15(name: "Rig15")
        XCTAssertNotNil(r15.findFirstChild("UpperTorso"))

        let block = InstanceFactory.create("Part")
        block.name = "Box"
        let wrapped = CharacterBuilder.wrapCustomCharacter(block, name: "Player1")
        XCTAssertEqual(wrapped.className, "Model")
        XCTAssertNotNil(wrapped.findFirstChild("HumanoidRootPart"))
        XCTAssertNotNil(wrapped.findFirstChildOfClass("Humanoid"))
    }

    func testCurveAnimDefaultAnimateAndEditAnimation() {
        // 1. CurveAnim.decode + eval + from
        func appendI32(_ d: inout Data, _ v: Int32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }
        func appendF32(_ d: inout Data, _ v: Float) {
            var le = v.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }
        var raw = Data()
        appendI32(&raw, 1) // header
        appendI32(&raw, 2) // 2 keys, stride 14 (interp:1, pad:1, val:4, lt:4, rt:4)
        raw.append(1); raw.append(0); appendF32(&raw, 0); appendF32(&raw, 0); appendF32(&raw, 0)
        raw.append(1); raw.append(0); appendF32(&raw, 10); appendF32(&raw, 0); appendF32(&raw, 0)
        appendI32(&raw, 1) // times header
        appendI32(&raw, 2) // 2 times
        appendI32(&raw, 0) // t = 0
        appendI32(&raw, 2400) // t = 1.0s

        let keys = CurveAnim.decode(raw)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(CurveAnim.eval(keys, 0.5), 5, accuracy: 0.001)

        let ca = Instance("CurveAnimation")
        let folder = Instance("Folder"); folder.name = "Head"; folder.attachRaw(ca)
        let v3c = Instance("Vector3Curve"); v3c.attachRaw(folder)
        let fc = Instance("FloatCurve"); fc.name = "Y"
        fc.set("ValuesAndTimes", .binaryString(BinaryString(raw)), notify: false)
        fc.attachRaw(v3c)
        let clip = CurveAnim.from(ca)
        XCTAssertNotNil(clip)
        XCTAssertEqual(clip?.length ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(clip?.sample("Head", 0.5)?.position.y ?? 0, 5, accuracy: 0.05)

        // 2. DefaultAnimate tree + Disabled respect
        let rig = CharacterBuilder.buildR15(name: "Rig15")
        let animScript = DefaultAnimate.attach(to: rig, r15: true)
        XCTAssertNotNil(animScript)
        XCTAssertNotNil(DefaultAnimate.config(of: rig)?["run"])
        animScript?.set("Disabled", .bool(true))
        XCTAssertNil(DefaultAnimate.config(of: rig))

        // 3. EditAnimation registration + Motor6D seating in edit mode
        EditAnimation.shared.clear()
        let dm = PlaceFactory.newPlace(.empty)
        let r6 = CharacterBuilder.buildR6(name: "Dummy", at: .at(Vector3(0, 5, 0)))
        r6.attachRaw(dm.workspace)
        let host = PluginHost(model: dm)
        host.runCommand("""
        local ksp = game:GetService("KeyframeSequenceProvider")
        local ks = Instance.new("KeyframeSequence")
        local kf = Instance.new("Keyframe"); kf.Time = 0; kf.Parent = ks
        local p = Instance.new("Pose"); p.Name = "Head"; p.CFrame = CFrame.new(0, 2, 0); p.Parent = kf
        local id = ksp:RegisterKeyframeSequence(ks)
        assert(string.sub(id, 1, 10) == "rbxtemp://")
        local dummy = workspace:FindFirstChild("Dummy")
        local hum = dummy:FindFirstChildOfClass("Humanoid")
        local anim = Instance.new("Animation"); anim.AnimationId = id
        local tr = hum:LoadAnimation(anim)
        tr:Play(0)
        """)
        host.step(0.05)
        let head = r6.findFirstChild("Head")!
        let torso = r6.findFirstChild("Torso")!
        XCTAssertGreaterThan(PartData.cframe(head).position.y, PartData.cframe(torso).position.y + 2.5)
        EditAnimation.shared.clear()
    }

    func testVehicleSeatCarDrivingAndMovers() throws {
        let dm = PlaceFactory.newPlace(.empty)
        let ws = dm.workspace

        let floor = InstanceFactory.create("Part")
        floor.name = "Floor"
        floor.set("Anchored", .bool(true), notify: false)
        floor.set("size", .vector3(Vector3(300, 2, 300)), notify: false)
        floor.set("CFrame", .cframe(.at(Vector3(0, -1, 0))), notify: false)
        floor.attachRaw(ws)

        let car = InstanceFactory.create("Model")
        car.name = "Car"
        car.attachRaw(ws)

        let chassis = InstanceFactory.create("Part")
        chassis.name = "Chassis"
        chassis.set("size", .vector3(Vector3(4, 1, 8)), notify: false)
        chassis.set("CFrame", .cframe(.at(Vector3(20, 3, 0))), notify: false)
        chassis.attachRaw(car)

        let seat = InstanceFactory.create("VehicleSeat")
        seat.name = "DriveSeat"
        seat.set("size", .vector3(Vector3(2, 1, 2)), notify: false)
        seat.set("CFrame", .cframe(.at(Vector3(20, 4, 0))), notify: false)
        seat.set("MaxSpeed", .float(30), notify: false)
        seat.set("Torque", .float(20), notify: false)
        seat.set("TurnSpeed", .float(2), notify: false)
        seat.attachRaw(car)

        let seatWeld = InstanceFactory.create("WeldConstraint")
        seatWeld.set("Part0", .ref(chassis), notify: false)
        seatWeld.set("Part1", .ref(seat), notify: false)
        seatWeld.attachRaw(seat)

        let wheelOffsets = [
            ("WheelFL", Vector3(-2.5, -1, -2.5)),
            ("WheelFR", Vector3(2.5, -1, -2.5)),
            ("WheelRL", Vector3(-2.5, -1, 2.5)),
            ("WheelRR", Vector3(2.5, -1, 2.5)),
        ]
        for (wName, off) in wheelOffsets {
            let wheel = InstanceFactory.create("Part")
            wheel.name = wName
            wheel.set("size", .vector3(Vector3(2, 2, 2)), notify: false)
            wheel.set("CFrame", .cframe(.at(Vector3(20, 3, 0) + off)), notify: false)
            wheel.attachRaw(car)

            let a0 = InstanceFactory.create("Attachment")
            a0.name = "Mount"
            a0.set("CFrame", .cframe(.at(off)), notify: false)
            a0.attachRaw(chassis)

            let a1 = InstanceFactory.create("Attachment")
            a1.name = "Axle"
            a1.attachRaw(wheel)

            let hinge = InstanceFactory.create("HingeConstraint")
            hinge.set("Attachment0", .ref(a0), notify: false)
            hinge.set("Attachment1", .ref(a1), notify: false)
            hinge.attachRaw(chassis)
        }

        let moverPart = InstanceFactory.create("Part")
        moverPart.name = "MoverBox"
        moverPart.set("size", .vector3(Vector3(2, 2, 2)), notify: false)
        moverPart.set("CFrame", .cframe(.at(Vector3(-30, 5, 0))), notify: false)
        moverPart.attachRaw(ws)

        let bv = InstanceFactory.create("BodyVelocity")
        bv.set("Velocity", .vector3(Vector3(20, 0, 0)), notify: false)
        bv.set("MaxForce", .vector3(Vector3(5000, 5000, 5000)), notify: false)
        bv.attachRaw(moverPart)

        let play = PlaySession(editModel: dm)
        var errors: [String] = []
        play.onOutput = { lvl, msg in if lvl == .error { errors.append(msg) } }
        play.start()
        defer { play.stop() }

        for _ in 0..<25 { play.step(1 / 30) }

        let playCar = try XCTUnwrap(play.dm.workspace.findFirstChild("Car"))
        let playSeat = try XCTUnwrap(playCar.findFirstChild("DriveSeat"))
        let playWheelFL = try XCTUnwrap(playCar.findFirstChild("WheelFL"))
        let playMover = try XCTUnwrap(play.dm.workspace.findFirstChild("MoverBox"))

        // HingeConstraint holds wheels attached to the car assembly after falling onto the floor.
        let relAfterFall = PartData.cframe(playWheelFL).position - PartData.cframe(playSeat).position
        XCTAssertEqual(relAfterFall.x, -2.5, accuracy: 0.1)
        XCTAssertEqual(relAfterFall.y, -2.0, accuracy: 0.1)
        XCTAssertEqual(relAfterFall.z, -2.5, accuracy: 0.1)

        // BodyVelocity drives moverPart horizontally while holding altitude.
        XCTAssertGreaterThan(PartData.cframe(playMover).position.x, -20)
        XCTAssertEqual(PartData.cframe(playMover).position.y, 5, accuracy: 0.5)

        // Luau Attachment.WorldPosition & VehicleSeat:Sit(humanoid).
        play.rt.runCommand("""
        local car = workspace:FindFirstChild("Car")
        local seat = car:FindFirstChild("DriveSeat")
        local att = car:FindFirstChild("Chassis"):FindFirstChild("Mount")
        assert((att.WorldPosition - car.WheelFL.Position).Magnitude < 0.05)
        local plr = game:GetService("Players").LocalPlayer
        local hum = plr.Character:FindFirstChildOfClass("Humanoid")
        seat:Sit(hum)
        assert(seat.Occupant == hum and hum.SeatPart == seat and hum.Sit == true)
        """)
        XCTAssertTrue(errors.isEmpty, "Unexpected Luau errors: \(errors)")
        XCTAssertTrue(play.seatedVehicle === playSeat)

        // Drive forward.
        let startZ = PartData.cframe(playSeat).position.z
        play.moveInput = Vector2(0, 1)
        for _ in 0..<30 { play.step(1 / 30) }
        XCTAssertEqual(playSeat.get("Throttle")?.asFloat ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(playSeat.get("ThrottleFloat")?.asFloat ?? 0, 1, accuracy: 0.01)
        XCTAssertTrue(play.keyDown("W"))
        XCTAssertLessThan(PartData.cframe(playSeat).position.z, startZ - 5)

        let root = try XCTUnwrap(play.character?.findFirstChild("HumanoidRootPart"))
        XCTAssertLessThan((PartData.cframe(root).position - PartData.cframe(playSeat).position).magnitude, 4.0)

        // Steer right while moving forward -> car lookVector turns toward +X.
        play.moveInput = Vector2(1, 1)
        for _ in 0..<15 { play.step(1 / 30) }
        XCTAssertEqual(playSeat.get("Steer")?.asFloat ?? 0, 1, accuracy: 0.01)
        XCTAssertGreaterThan(PartData.cframe(playSeat).lookVector.x, 0.2)

        // Jump leaves the seat cleanly and clears throttle/steer/virtual keys.
        play.moveInput = .zero
        play.requestJump()
        for _ in 0..<5 { play.step(1 / 30) }
        XCTAssertNil(play.seatedVehicle)
        XCTAssertNil(playSeat.get("Occupant")?.asInstance)
        XCTAssertEqual(playSeat.get("Throttle")?.asFloat ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(playSeat.get("Steer")?.asFloat ?? -1, 0, accuracy: 0.01)
        XCTAssertFalse(play.keyDown("W"))
    }
}
