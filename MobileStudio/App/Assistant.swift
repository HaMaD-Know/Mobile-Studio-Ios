import Foundation
import StudioCore

/// AI Assistant (port of ai/ClaudeAssistant.kt + ai/StudioTools.kt): a Claude tool-use loop over the
/// Messages API with the user's own Anthropic API key. Claude looks at and changes the open place
/// through seven studio tools. Each response's content blocks are sent back unchanged.
@MainActor
final class Assistant: ObservableObject {
    struct Item: Identifiable {
        enum Kind { case user, assistant, tool, notice, error }
        let id = UUID()
        let kind: Kind
        var text: String
    }

    static let models: [(String, String)] = [("claude-opus-5-5", "Claude Opus 5.5"), ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
                                             ("claude-haiku-5-5", "Claude Haiku 5.5")]
    static let efforts: [(String, String)] = [("low", "Low (fastest)"), ("medium", "Medium (recommended)"), ("high", "High"),
                                              ("xhigh", "Extra high (slowest, most careful)")]
    static let suggestions = ["Build a small wooden house next to the spawn", "Make the selected part spin slowly",
                              "Add a leaderboard with Coins", "Make a 10-stage obby with checkpoints",
                              "Generate a mountain island with terrain", "Add a day and night cycle"]

    static let guide = """
    You are the AI assistant inside Mobile Studio, a Roblox Studio for iPhone and iPad. You help the user build their Roblox place: \
    create parts, models, terrain, lighting and GUIs, and write scripts. Work through the tools: look before you change things \
    (get_tree, get_selection), then build with run_luau (Instance.new, then set properties and Parent) and write game code with \
    set_script. Use Roblox's real APIs and Luau; studs for distances; Anchored parts for static builds. Group what you build in a \
    Model with a clear name, and place it where the user can see it (near the spawn or the selection). Terrain works too: \
    workspace.Terrain:FillBlock/FillBall/FillCylinder(..., Enum.Material.Grass). When a script is meant to run in the game, it runs \
    when the user presses Play. Keep replies short: say what you made and where.
    """

    @Published var items: [Item] = []
    @Published var busy = false
    @Published var status = ""
    @Published var model = UserDefaults.standard.string(forKey: "ai.model") ?? "claude-opus-5-5" {
        didSet { UserDefaults.standard.set(model, forKey: "ai.model") }
    }
    @Published var effort = UserDefaults.standard.string(forKey: "ai.effort") ?? "medium" {
        didSet { UserDefaults.standard.set(effort, forKey: "ai.effort") }
    }
    /// Place bytes from before the last request ("Undo AI changes").
    @Published private(set) var snapshot: Data?

    private var history: [Any] = []
    private var task: Task<Void, Never>?
    weak var store: StudioStore?

    var hasKey: Bool { AccountStore.shared.anthropicKey != nil }

    func newChat() {
        stop()
        history = []
        items = []
    }

    func stop() {
        task?.cancel()
        task = nil
        busy = false
        status = ""
    }

    // MARK: key check

    /// Checks a key with the (free) models list call.
    static func checkKey(_ key: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 20
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 { return nil }
            if code == 401 || code == 403 { return "That key didn't work" }
            return "Couldn't check the key (HTTP \(code))"
        } catch { return error.localizedDescription }
    }

    // MARK: conversation

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy, let store, let key = AccountStore.shared.anthropicKey else { return }
        store.commitScripts()
        snapshot = store.placeData()
        items.append(Item(kind: .user, text: t))
        history.append(["role": "user", "content": t])
        busy = true
        status = "Thinking…"
        task = Task { [weak self] in
            await self?.run(key: key)
        }
    }

    private func run(key: String) async {
        defer { busy = false; status = ""; task = nil }
        for _ in 0..<40 {
            if Task.isCancelled { return }
            let response: [String: Any]
            do {
                response = try await request(key: key)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                items.append(Item(kind: .error, text: error.localizedDescription))
                // Drop the unanswered user turn so the next message starts cleanly.
                if let last = history.last as? [String: Any], last["role"] as? String == "user", last["content"] is String { history.removeLast() }
                return
            }
            let content = response["content"] as? [Any] ?? []
            history.append(["role": "assistant", "content": content])
            for case let block as [String: Any] in content where block["type"] as? String == "text" {
                if let s = block["text"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    items.append(Item(kind: .assistant, text: s))
                }
            }
            switch response["stop_reason"] as? String {
            case "tool_use":
                status = "Writing…"
                var results: [Any] = []
                for case let block as [String: Any] in content where block["type"] as? String == "tool_use" {
                    let name = block["name"] as? String ?? ""
                    let id = block["id"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    let (out, isError) = runTool(name, input)
                    results.append(["type": "tool_result", "tool_use_id": id, "content": out, "is_error": isError])
                }
                history.append(["role": "user", "content": results])
                status = "Thinking…"
            case "refusal":
                items.append(Item(kind: .notice, text: "Claude declined this request."))
                return
            case "max_tokens":
                items.append(Item(kind: .notice, text: "The reply hit its length limit. Ask Claude to continue."))
                return
            case "pause_turn":
                continue
            default:
                return
            }
        }
    }

    private func request(key: String) async throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": [["type": "text", "text": Self.guide]],
            "messages": history,
            "tools": Self.toolDefs,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": effort],
            "cache_control": ["type": "ephemeral"],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if model != "claude-haiku-5-5" {
            // Server-side refusal fallback: the API re-runs a declined request on a suitable model.
            body["fallbacks"] = "default"
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        req.timeoutInterval = 600
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        var attempt = 0
        while true {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if code == 200 { return json }
            let retry = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-should-retry")
            if (code == 429 || code >= 500 || code == 408) && retry != "false" && attempt < 2 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                continue
            }
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(code)"
            switch code {
            case 401: throw AssistantError("Your Anthropic API key was rejected. Check it in the Assistant menu.")
            case 429: throw AssistantError("Rate limited by the Anthropic API. Try again in a moment.")
            default: throw AssistantError(msg)
            }
        }
    }

    func undoAIChanges() {
        guard let s = snapshot, let store else { store?.showToast("No AI changes to undo"); return }
        do {
            try store.restoreSnapshot(s)
            snapshot = nil
            items.append(Item(kind: .notice, text: "Undid the last AI changes."))
        } catch { store.showToast("Couldn't undo: \(error.localizedDescription)") }
    }

    // MARK: studio tools (StudioTools.kt)

    static let toolDefs: [[String: Any]] = [
        def("run_luau", "Run Luau code in Roblox Studio's edit mode, like the command bar (game, workspace, Instance.new, services, Enum, CFrame, Vector3, Color3, TweenService...). Use it to create, change or delete things in the open place. Parent new instances (e.g. to workspace) or they won't appear. Anything you print() is returned, as are errors. Code runs once, right away; task.wait() pauses only the script, so put long-running game logic in Scripts instead.",
            ["code": ["type": "string", "description": "Luau source to run"]], ["code"]),
        def("get_tree", "List the Explorer tree under an instance: each line is the instance name and (ClassName), indented by depth. Paths are dot-separated from game, e.g. \"Workspace.Map.Tower\" or \"ServerScriptService\".",
            ["path": ["type": "string", "description": "Instance path; \"game\" for the whole place"],
             "depth": ["type": "integer", "description": "How many levels to list (1-6)"]], ["path", "depth"]),
        def("get_properties", "Read an instance's properties (name = value lines) and its child count.",
            ["path": ["type": "string", "description": "Instance path, e.g. \"Workspace.Baseplate\""]], ["path"]),
        def("get_script", "Read the Source of a Script, LocalScript or ModuleScript.",
            ["path": ["type": "string", "description": "Path of the script"]], ["path"]),
        def("set_script", "Replace a script's Source. If the script doesn't exist, it's created at that path with the given class (Script runs on the server, LocalScript on the client, ModuleScript is required by others).",
            ["path": ["type": "string", "description": "Path of the script, e.g. \"ServerScriptService.GameLoop\""],
             "source": ["type": "string", "description": "The complete new Luau source"],
             "class_name": ["type": "string", "enum": ["Script", "LocalScript", "ModuleScript"], "description": "Class used when creating the script"]],
            ["path", "source", "class_name"]),
        def("get_selection", "List the paths of what's selected in Studio (the user may refer to \"this\" or \"the selected part\").", [:], []),
        def("get_output", "Read the most recent lines of Studio's Output window (prints, warnings and script errors).",
            ["lines": ["type": "integer", "description": "How many recent lines (1-200)"]], ["lines"]),
    ]

    private static func def(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["name": name, "description": desc,
         "input_schema": ["type": "object", "properties": props, "required": required, "additionalProperties": false]]
    }

    private static let labels = ["run_luau": "Ran code", "get_tree": "Looked at Explorer", "get_properties": "Read properties",
                                 "get_script": "Read script", "set_script": "Wrote script", "get_selection": "Checked selection",
                                 "get_output": "Read Output"]

    private func path(_ i: Instance) -> String { i is DataModel ? "game" : i.fullName() }

    private func resolve(_ raw: String) -> Instance? {
        guard let store else { return nil }
        var p = raw.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("game") { p = String(p.dropFirst(4)) }
        if p.hasPrefix(".") { p = String(p.dropFirst()) }
        var cur: Instance = store.model
        for part in p.split(separator: ".").map(String.init) where !part.isEmpty {
            guard let next = cur.findFirstChild(part) ?? (cur is DataModel ? store.model.findService(part) : nil) else { return nil }
            cur = next
        }
        return cur
    }

    private func runTool(_ name: String, _ a: [String: Any]) -> (String, Bool) {
        guard let store else { return ("Studio isn't available", true) }
        var label = Self.labels[name] ?? name
        defer { items.append(Item(kind: .tool, text: label)) }
        func int(_ k: String, _ d: Int) -> Int { (a[k] as? Int) ?? (a[k] as? Double).map(Int.init) ?? d }
        switch name {
        case "run_luau":
            guard let code = a["code"] as? String else { return ("Missing code", true) }
            store.outputCapture = []
            store.runCommand(code)
            let out = store.outputCapture ?? []
            store.outputCapture = nil
            let failed = out.contains { $0.hasPrefix("Error: ") }
            return (out.isEmpty ? "Ran without output." : out.suffix(80).joined(separator: "\n"), failed)
        case "get_tree":
            guard let root = resolve(a["path"] as? String ?? "game") else { return ("No instance at that path", true) }
            let depth = min(6, max(1, int("depth", 2)))
            var lines: [String] = []
            func walk(_ i: Instance, _ d: Int) {
                guard lines.count < 600 else { return }
                lines.append(String(repeating: "  ", count: d) + (i is DataModel ? "game" : i.name) + " (\(i.className))")
                if d < depth { for c in i.children { walk(c, d + 1) } }
            }
            walk(root, 0)
            if lines.count >= 600 { lines.append("… (more not shown)") }
            return (lines.joined(separator: "\n"), false)
        case "get_properties":
            guard let i = resolve(a["path"] as? String ?? "") else { return ("No instance at that path", true) }
            var lines = ["ClassName = \(i.className)", "Name = \(i.name)"]
            for k in i.props.keys where k != "Source" && k != "Name" {
                if case .binaryString? = i.props[k] { continue }
                lines.append("\(PropertyRow.displayName(k)) = \(i.props[k]?.description ?? "")")
            }
            lines.append("Children: \(i.children.count)")
            return (lines.joined(separator: "\n"), false)
        case "get_script":
            guard let i = resolve(a["path"] as? String ?? ""), i.isA("LuaSourceContainer") else { return ("No script at that path", true) }
            return (store.scriptDrafts[ObjectIdentifier(i)] ?? i.get("Source")?.description ?? "", false)
        case "set_script":
            guard let p = a["path"] as? String, let src = a["source"] as? String else { return ("Missing path or source", true) }
            let cls = a["class_name"] as? String ?? "Script"
            var target = resolve(p)
            if target == nil {
                var parts = p.split(separator: ".").map(String.init)
                if parts.first == "game" { parts.removeFirst() }
                guard let leaf = parts.popLast(), let parent = resolve(parts.joined(separator: ".")) else { return ("The parent of that path doesn't exist", true) }
                let s = store.session.insertObject(["Script", "LocalScript", "ModuleScript"].contains(cls) ? cls : "Script", into: parent)
                s.name = leaf
                target = s
                label = "Wrote script"
            }
            guard let t = target, t.isA("LuaSourceContainer") else { return ("That path isn't a script", true) }
            let wasOpen = store.openScripts.contains { $0 === t }
            if wasOpen { store.closeScript(t) }
            store.setProp(t, "Source", .string(src))
            if wasOpen { store.openScript(t) }
            return ("Wrote \(path(t)) (\(src.split(separator: "\n", omittingEmptySubsequences: false).count) lines)", false)
        case "get_selection":
            let sel = store.selection.map(path)
            return (sel.isEmpty ? "Nothing is selected." : sel.joined(separator: "\n"), false)
        case "get_output":
            let n = min(200, max(1, int("lines", 50)))
            return (store.output.suffix(n).map { $0.time + "  " + $0.text }.joined(separator: "\n"), false)
        default:
            label = "Unknown tool \(name)"
            return ("Unknown tool \(name)", true)
        }
    }
}

struct AssistantError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
