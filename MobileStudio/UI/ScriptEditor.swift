import SwiftUI
import UIKit
import StudioCore
import StudioScript

/// Luau code editor (port of ui/ScriptEditor.kt + ui/Autocomplete.kt): syntax colouring,
/// auto-indent and `end` insertion, context-aware completions, live syntax check, find.
struct ScriptEditorView: View {
    @ObservedObject var store: StudioStore
    let script: Instance
    @State private var text = ""
    @State private var completions: [Completion] = []
    @State private var syntaxError: String?
    @State private var cursor = 0
    @State private var findText = ""
    @State private var showFind = false
    @State private var editorRef = EditorRef()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showFind {
                    HStack {
                        TextField("Find", text: $findText).textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onSubmit { editorRef.find(findText) }
                        Button("Next") { editorRef.find(findText) }
                    }
                    .padding(8)
                }
                CodeTextView(text: $text, cursor: $cursor, ref: editorRef)
                    .onChange(of: text) { _, t in
                        syntaxError = ScriptSyntax.check(t)
                        completions = Autocomplete.complete(text: t, cursor: cursor, model: store.model, script: script)
                    }
                    .onChange(of: cursor) { _, c in completions = Autocomplete.complete(text: text, cursor: c, model: store.model, script: script) }
                if let e = syntaxError {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                }
                if !completions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(completions.prefix(30)) { c in
                                Button { editorRef.accept(c) } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: c.kind.symbol).font(.caption2).foregroundStyle(c.kind.tint)
                                        Text(c.label).font(.system(.footnote, design: .monospaced))
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    .background(.bar)
                }
            }
            .navigationTitle(script.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showFind.toggle() } label: { Image(systemName: "magnifyingglass") }
                    Button("Done") {
                        store.setProp(script, "Source", .string(text))
                        dismiss()
                    }
                }
            }
            .onAppear {
                text = script.get("Source")?.description ?? ""
                syntaxError = ScriptSyntax.check(text)
            }
        }
    }
}

final class EditorRef {
    weak var view: UITextView?
    var onAccept: ((Completion) -> Void)?
    func accept(_ c: Completion) { onAccept?(c) }
    func find(_ s: String) {
        guard let v = view, !s.isEmpty else { return }
        let ns = v.text as NSString
        let start = v.selectedRange.location + v.selectedRange.length
        var r = ns.range(of: s, options: .caseInsensitive, range: NSRange(location: start, length: ns.length - start))
        if r.location == NSNotFound { r = ns.range(of: s, options: .caseInsensitive) }
        guard r.location != NSNotFound else { return }
        v.selectedRange = r
        v.scrollRangeToVisible(r)
    }
}

/// UITextView with Luau highlighting and smart newline handling.
struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var cursor: Int
    let ref: EditorRef

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.delegate = context.coordinator
        v.autocorrectionType = .no
        v.autocapitalizationType = .none
        v.smartQuotesType = .no
        v.smartDashesType = .no
        v.spellCheckingType = .no
        v.keyboardType = .asciiCapable
        v.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1)
        v.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 40, right: 6)
        v.alwaysBounceVertical = true
        ref.view = v
        ref.onAccept = { [weak v, coord = context.coordinator] c in
            guard let v else { return }
            coord.insertCompletion(v, c)
        }
        v.attributedText = LuauHighlighter.highlight(text)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text {
            let sel = v.selectedRange
            v.attributedText = LuauHighlighter.highlight(text)
            v.selectedRange = NSRange(location: min(sel.location, (text as NSString).length), length: 0)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: CodeTextView
        init(_ p: CodeTextView) { parent = p }

        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange, replacementText rep: String) -> Bool {
            guard rep == "\n" else { return true }
            // Auto-indent, and close blocks with `end` (ScriptEditor.handleNewline).
            let ns = tv.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let line = ns.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var insert = "\n" + indent
            var tail = ""
            let opensBlock = trimmed.hasSuffix(" then") || trimmed.hasSuffix(" do") || trimmed == "do" || trimmed == "repeat" ||
                trimmed.hasPrefix("function ") || trimmed.hasPrefix("local function ") || trimmed.hasSuffix(")") && trimmed.contains("function(") ||
                trimmed == "else" || trimmed.hasPrefix("elseif ")
            if opensBlock {
                insert += "\t"
                let needsEnd = !(trimmed == "else" || trimmed.hasPrefix("elseif ")) && unbalancedEnds(tv.text) > 0
                if needsEnd { tail = "\n" + indent + (trimmed == "repeat" ? "until " : "end") + (trimmed.hasSuffix(")") && trimmed.contains("function(") && !trimmed.hasPrefix("local function") && !trimmed.hasPrefix("function") ? ")" : "") }
            }
            tv.textStorage.replaceCharacters(in: range, with: insert + tail)
            tv.selectedRange = NSRange(location: range.location + (insert as NSString).length, length: 0)
            textViewDidChange(tv)
            return false
        }

        /// Blocks opened minus `end`s closed (rough count, ignoring strings/comments).
        func unbalancedEnds(_ text: String) -> Int {
            var opens = 0, ends = 0
            for line in text.split(separator: "\n") {
                let code = line.components(separatedBy: "--").first ?? ""
                let words = code.split(whereSeparator: { !$0.isLetter && $0 != "_" })
                for w in words {
                    switch w {
                    case "function", "do", "then", "repeat": opens += 1
                    case "end", "until": ends += 1
                    case "elseif": ends += 1
                    case "while", "for": opens -= 0
                    default: break
                    }
                }
                // `while ... do` / `for ... do` count once via `do`; `if ... then` once via `then`.
            }
            return opens - ends
        }

        func textViewDidChange(_ tv: UITextView) {
            let sel = tv.selectedRange
            let new = LuauHighlighter.highlight(tv.text)
            tv.textStorage.setAttributedString(new)
            tv.selectedRange = sel
            parent.text = tv.text
            parent.cursor = sel.location
        }

        func textViewDidChangeSelection(_ tv: UITextView) { parent.cursor = tv.selectedRange.location }

        func insertCompletion(_ tv: UITextView, _ c: Completion) {
            let ns = tv.text as NSString
            let cur = tv.selectedRange.location
            var start = cur
            while start > 0, let ch = UnicodeScalar(ns.character(at: start - 1)), CharacterSet.alphanumerics.contains(ch) || ch == "_" { start -= 1 }
            tv.textStorage.replaceCharacters(in: NSRange(location: start, length: cur - start), with: c.insert)
            tv.selectedRange = NSRange(location: start + (c.insert as NSString).length, length: 0)
            textViewDidChange(tv)
        }
    }
}

/// Luau token colouring (ScriptEditor.highlight; Roblox Studio dark theme colours).
enum LuauHighlighter {
    static let keywords: Set<String> = ["and", "break", "continue", "do", "else", "elseif", "end", "false", "for", "function", "if",
                                        "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "export", "type"]
    static let builtins: Set<String> = ["game", "workspace", "script", "print", "warn", "error", "wait", "task", "require", "pairs", "ipairs",
                                        "math", "string", "table", "coroutine", "Instance", "Vector3", "Vector2", "CFrame", "Color3", "UDim2",
                                        "UDim", "Enum", "tick", "time", "typeof", "type", "tostring", "tonumber", "pcall", "xpcall", "select",
                                        "setmetatable", "getmetatable", "rawget", "rawset", "next", "unpack", "BrickColor", "TweenInfo",
                                        "Ray", "Random", "os", "utf8", "bit32", "buffer", "shared", "_G", "self", "delay", "spawn"]
    static let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    static let base = UIColor(white: 0.86, alpha: 1)
    static let kw = UIColor(red: 0.97, green: 0.43, blue: 0.43, alpha: 1)
    static let bi = UIColor(red: 0.52, green: 0.84, blue: 0.97, alpha: 1)
    static let str = UIColor(red: 0.68, green: 0.95, blue: 0.48, alpha: 1)
    static let num = UIColor(red: 1.0, green: 0.78, blue: 0.40, alpha: 1)
    static let com = UIColor(white: 0.5, alpha: 1)

    static func highlight(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: base])
        let s = Array(text.utf16)
        var i = 0
        func color(_ a: Int, _ b: Int, _ c: UIColor) { out.addAttribute(.foregroundColor, value: c, range: NSRange(location: a, length: max(0, b - a))) }
        func isId(_ c: UInt16) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        while i < s.count {
            let c = s[i]
            if c == 45, i + 1 < s.count, s[i + 1] == 45 { // --
                var j = i + 2
                if j < s.count, s[j] == 91, let close = longClose(s, j) { color(i, close, com); i = close; continue }
                while j < s.count && s[j] != 10 { j += 1 }
                color(i, j, com); i = j; continue
            }
            if c == 34 || c == 39 || c == 96 { // " ' `
                var j = i + 1
                while j < s.count && s[j] != c && s[j] != 10 { if s[j] == 92 { j += 1 }; j += 1 }
                j = min(s.count, j + 1)
                color(i, j, str); i = j; continue
            }
            if c == 91, let close = longClose(s, i) { color(i, close, str); i = close; continue }
            if c >= 48 && c <= 57 {
                var j = i
                while j < s.count && (isId(s[j]) || s[j] == 46) { j += 1 }
                color(i, j, num); i = j; continue
            }
            if isId(c) {
                var j = i
                while j < s.count && isId(s[j]) { j += 1 }
                let w = String(utf16CodeUnits: Array(s[i..<j]), count: j - i)
                if keywords.contains(w) { color(i, j, kw) } else if builtins.contains(w) { color(i, j, bi) }
                i = j; continue
            }
            i += 1
        }
        return out
    }

    /// End of a [[...]] / [==[...]==] long bracket starting at `at`, if it is one.
    static func longClose(_ s: [UInt16], _ at: Int) -> Int? {
        var j = at + 1, level = 0
        while j < s.count && s[j] == 61 { level += 1; j += 1 }
        guard j < s.count, s[j] == 91 else { return nil }
        var k = j + 1
        while k < s.count {
            if s[k] == 93 {
                var m = k + 1, l = 0
                while m < s.count && s[m] == 61 { l += 1; m += 1 }
                if l == level && m < s.count && s[m] == 93 { return m + 1 }
            }
            k += 1
        }
        return s.count
    }
}

struct Completion: Identifiable {
    enum Kind {
        case keyword, global, property, method, event, child, enumItem, local, service
        var symbol: String {
            switch self {
            case .keyword: "textformat"
            case .global: "globe"
            case .property: "p.circle"
            case .method: "m.circle"
            case .event: "bolt.fill"
            case .child: "cube"
            case .enumItem: "list.bullet"
            case .local: "l.circle"
            case .service: "gearshape"
            }
        }
        var tint: Color {
            switch self {
            case .keyword: .red
            case .method: .purple
            case .event: .yellow
            case .property: .blue
            case .child: .gray
            default: .teal
            }
        }
    }
    let label: String
    let kind: Kind
    var insert: String
    var id: String { "\(kind)\(label)" }
}

/// Context-aware completion (simplified port of ui/Autocomplete.kt).
enum Autocomplete {
    static func members(_ cls: String) -> ([String], [String], [String]) {
        var p: [String] = [], m: [String] = [], e: [String] = []
        var c: String? = cls
        var guardCount = 0
        while let cur = c, guardCount < 20 {
            if let t = AutocompleteTables.members[cur] { p += t.0; m += t.1; e += t.2 }
            c = ClassDb.superclass(cur)
            guardCount += 1
        }
        return (p, m, e)
    }

    /// Resolve `a.b.c` before the cursor to an Instance in the edit model.
    static func resolve(_ chain: [String], model: DataModel, script: Instance) -> Instance? {
        guard let first = chain.first else { return nil }
        var cur: Instance?
        switch first {
        case "game", "Game": cur = model
        case "workspace", "Workspace": cur = model.workspace
        case "script": cur = script
        default: return nil
        }
        for name in chain.dropFirst() {
            guard let c = cur else { return nil }
            if name == "Parent" { cur = c.parent; continue }
            if c is DataModel, ClassDb.isServiceName(name) { cur = model.findService(name) ?? model.getService(name); continue }
            cur = c.findFirstChild(name)
        }
        return cur
    }

    static func complete(text: String, cursor: Int, model: DataModel, script: Instance) -> [Completion] {
        let ns = text as NSString
        guard cursor <= ns.length else { return [] }
        let before = ns.substring(to: cursor)
        // Inside a string after GetService(" -> service names.
        if let r = before.range(of: "GetService(\"", options: .backwards), !before[r.upperBound...].contains("\"") {
            let prefix = String(before[r.upperBound...])
            return rank(ClassDb.serviceNames.map { Completion(label: $0, kind: .service, insert: $0) }, prefix)
        }
        var i = before.endIndex
        while i > before.startIndex, let ch = before[before.index(before: i)].unicodeScalars.first,
              CharacterSet.alphanumerics.contains(ch) || ch == "_" { i = before.index(before: i) }
        let prefix = String(before[i...])
        guard i > before.startIndex else { return prefix.isEmpty ? [] : globals(text, prefix) }
        let accessor = before[before.index(before: i)]
        guard accessor == "." || accessor == ":" else { return prefix.isEmpty ? [] : globals(text, prefix) }
        // Collect the dotted chain before the accessor.
        var j = before.index(before: i)
        var chainText = ""
        while j > before.startIndex {
            let ch = before[before.index(before: j)]
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "." { chainText.insert(ch, at: chainText.startIndex); j = before.index(before: j) } else { break }
        }
        let chain = chainText.split(separator: ".").map(String.init)
        if chain == ["Enum"] { return rank(ScriptEnumNames.all.map { Completion(label: $0, kind: .enumItem, insert: $0) }, prefix) }
        if chain.count == 2, chain[0] == "Enum" {
            return rank((Enums.items(chain[1])).map { Completion(label: $0.0, kind: .enumItem, insert: $0.0) }, prefix)
        }
        if let lib = libraries[chain.first ?? ""], chain.count == 1 {
            return rank(lib.map { Completion(label: $0, kind: .method, insert: $0) }, prefix)
        }
        guard let inst = resolve(chain, model: model, script: script) else { return [] }
        let (props, methods, events) = members(inst.className)
        if accessor == ":" { return rank(methods.map { Completion(label: $0, kind: .method, insert: $0) }, prefix) }
        var items = inst.children.map { Completion(label: $0.name, kind: .child, insert: $0.name.contains(" ") ? $0.name : $0.name) }
        items += props.map { Completion(label: $0, kind: .property, insert: $0) }
        items += events.map { Completion(label: $0, kind: .event, insert: $0) }
        if inst is DataModel { items += ClassDb.serviceNames.map { Completion(label: $0, kind: .service, insert: $0) } }
        return rank(items, prefix)
    }

    static let libraries: [String: [String]] = [
        "math": ["abs", "acos", "asin", "atan", "atan2", "ceil", "clamp", "cos", "cosh", "deg", "exp", "floor", "fmod", "frexp", "huge",
                 "ldexp", "log", "log10", "max", "min", "modf", "noise", "pi", "pow", "rad", "random", "randomseed", "round", "sign", "sin",
                 "sinh", "sqrt", "tan", "tanh", "lerp", "map"],
        "string": ["byte", "char", "find", "format", "gmatch", "gsub", "len", "lower", "match", "rep", "reverse", "split", "sub", "upper", "pack", "unpack"],
        "table": ["clear", "clone", "concat", "create", "find", "freeze", "insert", "isfrozen", "maxn", "move", "pack", "remove", "sort", "unpack"],
        "task": ["spawn", "defer", "delay", "wait", "cancel", "synchronize", "desynchronize"],
        "coroutine": ["create", "resume", "running", "status", "wrap", "yield", "isyieldable", "close"],
        "Vector3": ["new", "zero", "one", "xAxis", "yAxis", "zAxis", "FromNormalId", "FromAxis"],
        "CFrame": ["new", "lookAt", "Angles", "fromEulerAnglesXYZ", "fromEulerAnglesYXZ", "fromOrientation", "fromAxisAngle", "fromMatrix", "identity"],
        "Color3": ["new", "fromRGB", "fromHSV", "fromHex", "toHSV"],
        "UDim2": ["new", "fromScale", "fromOffset"],
        "Instance": ["new", "fromExisting"],
        "TweenInfo": ["new"],
        "BrickColor": ["new", "random", "palette", "White", "Gray", "DarkGray", "Black", "Red", "Yellow", "Green", "Blue"],
    ]

    static func globals(_ text: String, _ prefix: String) -> [Completion] {
        var items = LuauHighlighter.keywords.sorted().map { Completion(label: $0, kind: .keyword, insert: $0) }
        items += LuauHighlighter.builtins.sorted().map { Completion(label: $0, kind: .global, insert: $0) }
        // Locals declared in the script.
        let pattern = try? NSRegularExpression(pattern: "local\\s+(?:function\\s+)?([A-Za-z_][A-Za-z0-9_]*)")
        let ns = text as NSString
        let locals = Set(pattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) } ?? [])
        items += locals.sorted().map { Completion(label: $0, kind: .local, insert: $0) }
        return rank(items, prefix)
    }

    static func rank(_ items: [Completion], _ prefix: String) -> [Completion] {
        let p = prefix.lowercased()
        var seen = Set<String>()
        let filtered = items.filter { p.isEmpty || $0.label.lowercased().hasPrefix(p) || ($0.label.lowercased().contains(p) && p.count >= 2) }
            .filter { seen.insert($0.label).inserted && $0.label != prefix }
        return filtered.sorted { a, b in
            let ap = a.label.lowercased().hasPrefix(p), bp = b.label.lowercased().hasPrefix(p)
            if ap != bp { return ap }
            return a.label.count < b.label.count
        }
    }
}

/// Enum type names for `Enum.` completion.
enum ScriptEnumNames {
    static var all: [String] { Array(EnumTable.types.keys).sorted() + ["KeyCode", "PlaybackState", "MouseBehavior", "EasingStyle", "EasingDirection"] }
}
