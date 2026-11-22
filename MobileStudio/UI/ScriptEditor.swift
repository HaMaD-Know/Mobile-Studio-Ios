import SwiftUI
import UIKit
import StudioCore
import StudioScript

/// Luau code editor shown as a document tab (port of ui/ScriptEditor.kt + ui/Autocomplete.kt):
/// path bar with line count, Check and Find, a line-number gutter, syntax colouring, auto-indent
/// and `end` insertion, completions and the symbol key bar.
struct ScriptDocView: View {
    @ObservedObject var store: StudioStore
    let script: Instance
    @State private var text = ""
    @State private var completions: [Completion] = []
    @State private var syntaxError: String?
    @State private var cursor = 0
    @State private var findText = ""
    @State private var showFind = false
    @State private var editorRef = EditorRef()

    static let keys = ["Tab", "(", ")", "{", "}", "[", "]", "=", "\"", ":", ".", ",", "~", "#", "end", "local", "function", "then"]

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            if showFind {
                HStack(spacing: 6) {
                    TextField("", text: $findText, prompt: Text("Find").foregroundStyle(Th.dim))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onSubmit { editorRef.find(findText) }
                        .studioField()
                    Button("Next") { editorRef.find(findText) }.foregroundStyle(Th.info)
                }
                .padding(6)
                .background(Th.header)
            }
            CodeTextView(text: $text, cursor: $cursor, ref: editorRef)
                .onChange(of: text) { _, t in
                    store.scriptDrafts[ObjectIdentifier(script)] = t
                    syntaxError = ScriptSyntax.check(t)
                    completions = Autocomplete.complete(text: t, cursor: cursor, model: store.model, script: script)
                }
                .onChange(of: cursor) { _, c in completions = Autocomplete.complete(text: text, cursor: c, model: store.model, script: script) }
            if let e = syntaxError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Th.warn).lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Th.header)
            }
            if !completions.isEmpty { completionBar }
            keyBar
        }
        .background(Th.editorBg)
        .onAppear {
            text = store.scriptDrafts[ObjectIdentifier(script)] ?? script.get("Source")?.description ?? ""
            syntaxError = ScriptSyntax.check(text)
        }
    }

    private var pathBar: some View {
        HStack(spacing: 10) {
            Image(systemName: ClassIcon.symbol(script.className)).foregroundStyle(ClassIcon.tint(script.className))
            Text(script.fullName()).font(.system(size: 15)).foregroundStyle(Th.text).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 6)
            Text("\(lineCount) lines").font(.system(size: 14)).foregroundStyle(Th.dim)
            Button {
                if let e = ScriptSyntax.check(text) { store.showToast(e) } else { store.showToast("No syntax errors") }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.rectangle.portrait.fill").foregroundStyle(Th.play)
                    Text("Check").foregroundStyle(Th.text)
                }
                .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            PanelIconButton(icon: "magnifyingglass") { showFind.toggle() }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Th.header)
    }

    private var lineCount: Int { text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }

    private var completionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(completions.prefix(30)) { c in
                    Button { editorRef.accept(c) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: c.kind.symbol).font(.system(size: 11)).foregroundStyle(c.kind.tint)
                            Text(c.label).font(.system(size: 13, design: .monospaced)).foregroundStyle(Th.text)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Th.hover, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
        }
        .background(Th.header)
    }

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Self.keys, id: \.self) { k in
                    Button { editorRef.insert(k == "Tab" ? "\t" : (k.count > 1 ? k + " " : k)) } label: {
                        Text(k).font(.system(size: 16)).foregroundStyle(Th.text)
                            .padding(.horizontal, 11).frame(height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Th.topbar)
    }
}

final class EditorRef {
    weak var view: UITextView?
    var onAccept: ((Completion) -> Void)?
    func accept(_ c: Completion) { onAccept?(c) }
    func insert(_ s: String) { view?.insertText(s) }
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

/// UITextView with a line-number gutter that scrolls with the text.
final class GutterTextView: UITextView {
    let gutter = LineGutterView()
    static let gutterWidth: CGFloat = 40

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        gutter.textView = self
        addSubview(gutter)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = max(contentSize.height, bounds.height) + 200
        let f = CGRect(x: 0, y: -100, width: Self.gutterWidth, height: h)
        if gutter.frame != f { gutter.frame = f; gutter.setNeedsDisplay() }
        sendSubviewToBack(gutter)
    }
}

final class LineGutterView: UIView {
    weak var textView: UITextView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let tv = textView else { return }
        let theme = ThemeStore.shared.current
        UIColor(argb: theme.editorGutter).setFill()
        UIRectFill(bounds)
        let lm = tv.layoutManager
        let ns = tv.text as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                                    .foregroundColor: UIColor(argb: theme.dim)]
        let inset = tv.textContainerInset.top
        var line = 1
        var charIndex = 0
        if ns.length == 0 {
            ("1" as NSString).draw(at: CGPoint(x: 8, y: inset + 100), withAttributes: attrs)
            return
        }
        while charIndex < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyph = lm.glyphIndexForCharacter(at: lineRange.location)
            let r = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = r.minY + inset + 100
            if y + r.height >= rect.minY && y <= rect.maxY {
                ("\(line)" as NSString).draw(at: CGPoint(x: 8, y: y + 1), withAttributes: attrs)
            }
            line += 1
            charIndex = NSMaxRange(lineRange)
        }
        if ns.hasSuffix("\n") {
            let r = lm.extraLineFragmentRect
            ("\(line)" as NSString).draw(at: CGPoint(x: 8, y: r.minY + inset + 101), withAttributes: attrs)
        }
    }
}

/// UITextView with Luau highlighting and smart newline handling.
struct CodeTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var cursor: Int
    let ref: EditorRef

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let v = GutterTextView(frame: .zero, textContainer: nil)
        v.delegate = context.coordinator
        v.autocorrectionType = .no
        v.autocapitalizationType = .none
        v.smartQuotesType = .no
        v.smartDashesType = .no
        v.spellCheckingType = .no
        v.keyboardType = .asciiCapable
        v.backgroundColor = UIColor(argb: ThemeStore.shared.current.editorBg)
        v.tintColor = UIColor(argb: ThemeStore.shared.current.accent)
        v.textContainerInset = UIEdgeInsets(top: 10, left: GutterTextView.gutterWidth + 6, bottom: 40, right: 6)
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
            (tv as? GutterTextView)?.gutter.setNeedsDisplay()
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
    static var base: UIColor { UIColor(argb: ThemeStore.shared.current.editorText) }
    static var kw: UIColor { UIColor(argb: ThemeStore.shared.current.synKeyword) }
    static var bi: UIColor { UIColor(argb: ThemeStore.shared.current.synBuiltin) }
    static var str: UIColor { UIColor(argb: ThemeStore.shared.current.synString) }
    static var num: UIColor { UIColor(argb: ThemeStore.shared.current.synNumber) }
    static var com: UIColor { UIColor(argb: ThemeStore.shared.current.synComment) }

    static func highlight(_ text: String) -> NSAttributedString {
        let base = Self.base, kw = Self.kw, bi = Self.bi, str = Self.str, num = Self.num, com = Self.com
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
