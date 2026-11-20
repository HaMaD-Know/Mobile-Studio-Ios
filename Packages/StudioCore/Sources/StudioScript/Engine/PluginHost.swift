import Foundation
import Luau
import StudioCore

/// Edit-time scripting (port of core/PluginManager.kt + lua/PluginApi.kt): runs Studio plugins
/// against the edit model with a `plugin` object, and the command bar.
public final class PluginHost {
    public let rt: ScriptRuntime
    public private(set) var plugins: [Instance] = []

    public struct Button: Identifiable {
        public let id: ObjectIdentifier
        public let inst: Instance
        public let toolbar: String
        public var text: String
        public var tooltip: String
        public var active: Bool
    }

    public init(model: DataModel) {
        rt = ScriptRuntime(dm: model, isPlay: false) { rt in
            rt.addGlobalTable("DockWidgetPluginGuiInfo", [
                "new": { c in
                    // Returned as a plain marker; CreateDockWidgetPluginGui only needs it to exist.
                    c.push("DockWidgetPluginGuiInfo")
                },
            ])
        }
    }

    public var onOutput: (OutputLevel, String) -> Void {
        get { rt.onOutput }
        set { rt.onOutput = newValue }
    }

    public func step(_ dt: Double) { rt.step(dt) }
    public func runCommand(_ code: String) { rt.runCommand(code) }

    /// Load a plugin from source (.lua) or a model file's roots.
    public func load(name: String, roots: [Instance]) {
        let p = Instance("Plugin")
        p.name = name
        p.archivable = false
        for r in roots { r.attachRaw(p) }
        plugins.append(p)
        for s in [p] + p.descendants() where s.className == "Script" && s.get("Disabled")?.asBool != true {
            rt.runScript(s)
        }
    }

    public func load(name: String, source: String) {
        let s = InstanceFactory.create("Script")
        s.name = name
        s.set("Source", .string(source), notify: false)
        load(name: name, roots: [s])
    }

    public func unloadAll() {
        for p in plugins { rt.fire(p, "Unloading"); rt.disconnectTree(p) }
        plugins.removeAll()
    }

    /// Toolbar buttons created by plugins.
    public func buttons() -> [Button] {
        plugins.flatMap { $0.descendants() }.filter { $0.className == "PluginToolbarButton" }.map { b in
            Button(id: ObjectIdentifier(b), inst: b, toolbar: b.parent?.name ?? "",
                   text: b.get("Text")?.asString ?? b.name, tooltip: b.get("Tooltip")?.asString ?? "",
                   active: b.get("Active")?.asBool == true)
        }
    }

    public func click(_ b: Instance) { rt.fire(b, "Click") }

    /// Visible dock widgets (rendered by the app like ScreenGuis).
    public func widgets() -> [Instance] {
        plugins.flatMap { $0.descendants() }.filter { $0.className == "DockWidgetPluginGui" && $0.get("Enabled")?.asBool == true }
    }

    public func layout(widget: Instance, size: Vector2) -> [GuiItem] {
        GuiLayout.layoutRoot(widget, viewport: size)
    }
    public func guiActivate(_ g: Instance) { rt.fire(g, "MouseButton1Click"); rt.fire(g, "Activated", [.table([]), .number(1)]) }
    public func guiText(_ g: Instance, _ text: String, enter: Bool) {
        g.set("Text", .string(text))
        if enter { rt.fire(g, "FocusLost", [.bool(true), .nil_]) }
    }
}

/// `plugin` / PluginToolbar / PluginToolbarButton methods (port of lua/PluginApi.kt).
enum PluginAPI {
    static func call(_ c: LuaCall, _ inst: Instance, _ m: String) throws -> Int32? {
        let rt = c.rt
        switch (inst.className, m) {
        case ("Plugin", "CreateToolbar"):
            let name = try c.checkString(2, m)
            let tb = inst.children.first { $0.className == "PluginToolbar" && $0.name == name } ?? {
                let t = Instance("PluginToolbar"); t.name = name; t.archivable = false; t.attachRaw(inst); return t
            }()
            c.push(tb); return 1
        case ("PluginToolbar", "CreateButton"):
            let id = try c.checkString(2, m)
            let b = Instance("PluginToolbarButton")
            b.name = id
            b.archivable = false
            b.set("Tooltip", .string(c.optString(3) ?? ""), notify: false)
            b.set("Icon", .string(c.optString(4) ?? ""), notify: false)
            b.set("Text", .string(c.optString(5) ?? id), notify: false)
            b.set("Active", .bool(false), notify: false)
            b.set("Enabled", .bool(true), notify: false)
            b.attachRaw(inst)
            rt.pluginsChanged()
            c.push(b); return 1
        case ("PluginToolbarButton", "SetActive"):
            inst.set("Active", .bool(c.bool(2))); rt.pluginsChanged(); return 0
        case ("Plugin", "Activate"): inst.set("Activated", .bool(true), notify: false); return 0
        case ("Plugin", "Deactivate"):
            inst.set("Activated", .bool(false), notify: false); rt.fire(inst, "Deactivation"); return 0
        case ("Plugin", "IsActivated"), ("Plugin", "IsActivatedWithExclusiveMouse"):
            c.push(inst.get("Activated")?.asBool == true); return 1
        case ("Plugin", "GetSetting"):
            let k = "plugin.\(inst.name).\(try c.checkString(2, m))"
            if let json = UserDefaults.standard.string(forKey: k), let v = try? JSON.decode(json) { c.push(v) } else { c.pushNil() }
            return 1
        case ("Plugin", "SetSetting"):
            let k = "plugin.\(inst.name).\(try c.checkString(2, m))"
            UserDefaults.standard.set(try JSON.encode(rt.readValue(c.L, 3)), forKey: k)
            return 0
        case ("Plugin", "GetMouse"):
            let mouse = inst.findFirstChildOfClass("PluginMouse") ?? { let x = Instance("PluginMouse"); x.archivable = false; x.attachRaw(inst); return x }()
            c.push(mouse); return 1
        case ("Plugin", "CreateDockWidgetPluginGui"), ("Plugin", "CreateDockWidgetPluginGuiAsync"), ("Plugin", "CreateQWidgetPluginGui"):
            let w = Instance("DockWidgetPluginGui")
            w.name = try c.checkString(2, m)
            w.archivable = false
            w.set("Title", .string(w.name), notify: false)
            w.set("Enabled", .bool(false), notify: false)
            w.attachRaw(inst)
            c.push(w); return 1
        case ("Plugin", "OpenScript"):
            if let s = c.instance(2) { rt.openScriptHandler(s) }
            return 0
        case ("Plugin", "GetStudioUserId"): c.push(0); return 1
        case ("Plugin", "GetJoinMode"): c.push(.enumItem(EnumItem(enumType: "JointCreationMode", name: "All", value: 0))); return 1
        case ("Plugin", "GetGridSize"): c.push(1); return 1
        case ("Plugin", "SelectRibbonTool"), ("Plugin", "SaveSelectedToRoblox"), ("Plugin", "OpenWikiPage"), ("Plugin", "StartDrag"): return 0
        case ("Plugin", "GetSelectedRibbonTool"): c.push(.enumItem(EnumItem(enumType: "RibbonTool", name: "None", value: 0))); return 1
        case ("Plugin", "PromptImportFile"), ("Plugin", "PromptImportFiles"): c.pushNil(); return 1
        case ("Plugin", "CreatePluginAction"), ("Plugin", "CreatePluginMenu"):
            let a = Instance(m == "CreatePluginAction" ? "PluginAction" : "PluginMenu")
            a.name = try c.checkString(2, m)
            a.archivable = false
            a.attachRaw(inst)
            c.push(a); return 1
        case ("Plugin", "Union"), ("Plugin", "Separate"):
            throw LuaError("plugin:\(m) (solid modeling) isn't available in scripts on this device")
        default: return nil
        }
    }

    static let methods: [String: Set<String>] = [
        "Plugin": ["CreateToolbar", "Activate", "Deactivate", "IsActivated", "IsActivatedWithExclusiveMouse", "GetSetting", "SetSetting",
                   "GetMouse", "CreateDockWidgetPluginGui", "CreateDockWidgetPluginGuiAsync", "CreateQWidgetPluginGui", "OpenScript",
                   "GetStudioUserId", "GetJoinMode", "GetGridSize", "SelectRibbonTool", "SaveSelectedToRoblox", "OpenWikiPage",
                   "StartDrag", "GetSelectedRibbonTool", "PromptImportFile", "PromptImportFiles", "CreatePluginAction",
                   "CreatePluginMenu", "Union", "Separate"],
        "PluginToolbar": ["CreateButton"],
        "PluginToolbarButton": ["SetActive"],
    ]
}

extension GuiLayout {
    /// Lay out the children of an arbitrary GUI root (dock widgets) filling `viewport`.
    public static func layoutRoot(_ root: Instance, viewport: Vector2) -> [GuiItem] {
        var out: [GuiItem] = []
        var order = 0
        let rect = (x: Float(0), y: Float(0), w: viewport.x, h: viewport.y)
        Gui.rects[ObjectIdentifier(root)] = rect
        children(root, rect, nil, 0, &out, &order)
        out.sort { ($0.zIndex, $0.order) < ($1.zIndex, $1.order) }
        return out
    }
}
