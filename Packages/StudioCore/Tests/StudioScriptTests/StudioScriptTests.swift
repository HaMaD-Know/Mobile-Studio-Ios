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
}
