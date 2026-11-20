import Foundation
import StudioCore

/// Flattened, laid-out GUI for drawing (port of ui/GuiOverlay.kt's layout pass).
public struct GuiItem {
    public enum Kind { case frame, text, textButton, textBox, image, imageButton, scroll }
    public let inst: Instance
    public let kind: Kind
    public var x: Float, y: Float, w: Float, h: Float
    public var clip: (x: Float, y: Float, w: Float, h: Float)?
    public var background: Color3
    public var backgroundAlpha: Float
    public var cornerRadius: Float
    public var stroke: (Color3, Float, Float)?   // color, thickness, alpha
    public var text: String
    public var textColor: Color3
    public var textAlpha: Float
    public var textSize: Float
    public var textScaled: Bool
    public var textWrapped: Bool
    public var xAlign: Int        // 0 left, 1 right, 2 center (Enum.TextXAlignment)
    public var yAlign: Int        // 0 top, 1 center, 2 bottom (Enum.TextYAlignment)
    public var bold: Bool
    public var font: String
    public var image: String
    public var imageColor: Color3
    public var imageAlpha: Float
    public var rotation: Float
    public var zIndex: Int
    public var order: Int
}

public enum GuiLayout {
    static func udim2(_ i: Instance, _ k: String, _ d: UDim2) -> UDim2 { if case .udim2(let u)? = i.get(k) { return u }; return d }
    static func udim(_ i: Instance, _ k: String) -> UDim { if case .udim(let u)? = i.get(k) { return u }; return UDim(0, 0) }
    static func color(_ i: Instance, _ k: String, _ d: Color3) -> Color3 { i.get(k)?.asColor3 ?? d }
    static func num(_ i: Instance, _ k: String, _ d: Float) -> Float { i.get(k)?.asFloat ?? d }

    /// Lay out every enabled ScreenGui under `playerGui` (plus BillboardGuis via `project`).
    public static func layout(playerGui: Instance?, workspace: Instance, viewport: Vector2,
                              project: (Vector3) -> (Vector3, Bool)) -> [GuiItem] {
        var out: [GuiItem] = []
        var order = 0
        Gui.rects.removeAll(keepingCapacity: true)
        let insetTop: Float = 58
        let guis = (playerGui?.children ?? []).filter { $0.className == "ScreenGui" && $0.get("Enabled")?.asBool != false }
            .sorted { Int($0.get("DisplayOrder")?.asFloat ?? 0) < Int($1.get("DisplayOrder")?.asFloat ?? 0) }
        for g in guis {
            let ignoreInset = g.get("IgnoreGuiInset")?.asBool == true
            let root = (x: Float(0), y: ignoreInset ? 0 : insetTop, w: viewport.x, h: viewport.y - (ignoreInset ? 0 : insetTop))
            Gui.rects[ObjectIdentifier(g)] = root
            children(g, root, nil, 0, &out, &order)
        }
        // BillboardGuis (in workspace or player gui) at their adornee's screen position.
        let billboards = workspace.descendants().filter { $0.className == "BillboardGui" } +
            (playerGui?.descendants().filter { $0.className == "BillboardGui" } ?? [])
        for b in billboards where b.get("Enabled")?.asBool != false {
            let adornee = b.get("Adornee")?.asInstance ?? b.parent
            guard let a = adornee, a.isA("BasePart") || a.className == "Attachment" else { continue }
            var pos = a.isA("BasePart") ? PartData.cframe(a).position : (a.parent.map { PartData.cframe($0) * (a.get("CFrame")?.asCFrame ?? .identity) }?.position ?? .zero)
            pos += b.get("StudsOffset")?.asVector3 ?? .zero
            pos += b.get("StudsOffsetWorldSpace")?.asVector3 ?? .zero
            let (s, on) = project(pos)
            guard on, s.z > 0 else { continue }
            if let maxD = b.get("MaxDistance")?.asFloat, maxD > 0, s.z > maxD { continue }
            let size = udim2(b, "Size", UDim2(0, 200, 0, 50))
            // Scale components are in studs for billboards: approximate with distance.
            let pxPerStud = viewport.y / (2 * s.z * tan(35 * .pi / 180))
            let w = size.x.scale * pxPerStud + Float(size.x.offset), h = size.y.scale * pxPerStud + Float(size.y.offset)
            let rect = (x: s.x - w / 2, y: s.y - h / 2, w: w, h: h)
            Gui.rects[ObjectIdentifier(b)] = rect
            children(b, rect, b.get("ClipsDescendants")?.asBool == true ? rect : nil, 0, &out, &order)
        }
        out.sort { ($0.zIndex, $0.order) < ($1.zIndex, $1.order) }
        return out
    }

    private static func padding(_ p: Instance?, _ r: (x: Float, y: Float, w: Float, h: Float)) -> (x: Float, y: Float, w: Float, h: Float) {
        guard let p else { return r }
        let l = udim(p, "PaddingLeft"), rt = udim(p, "PaddingRight"), t = udim(p, "PaddingTop"), b = udim(p, "PaddingBottom")
        let pl = l.scale * r.w + Float(l.offset), pr = rt.scale * r.w + Float(rt.offset)
        let pt = t.scale * r.h + Float(t.offset), pb = b.scale * r.h + Float(b.offset)
        return (r.x + pl, r.y + pt, max(0, r.w - pl - pr), max(0, r.h - pt - pb))
    }

    private static func children(_ parent: Instance, _ rect0: (x: Float, y: Float, w: Float, h: Float),
                                 _ clip: (x: Float, y: Float, w: Float, h: Float)?, _ baseZ: Int,
                                 _ out: inout [GuiItem], _ order: inout Int) {
        let rect = padding(parent.findFirstChildOfClass("UIPadding"), rect0)
        let objs = parent.children.filter { $0.isA("GuiObject") && $0.get("Visible")?.asBool != false }
        let list = parent.findFirstChildOfClass("UIListLayout")
        let grid = parent.findFirstChildOfClass("UIGridLayout")
        var cursor: Float = 0
        var sorted = objs
        if list != nil || grid != nil {
            let sortByName = (list ?? grid)?.get("SortOrder")?.asEnum == 0
            sorted.sort { a, b in
                if sortByName { return a.name < b.name }
                return Int(a.get("LayoutOrder")?.asFloat ?? 0) < Int(b.get("LayoutOrder")?.asFloat ?? 0)
            }
        }
        for (idx, g) in sorted.enumerated() {
            let size = udim2(g, "Size", UDim2(0, 100, 0, 100))
            var w = size.x.scale * rect.w + Float(size.x.offset), h = size.y.scale * rect.h + Float(size.y.offset)
            if let ar = g.findFirstChildOfClass("UIAspectRatioConstraint") {
                let ratio = num(ar, "AspectRatio", 1)
                if w / max(h, 0.001) > ratio { w = h * ratio } else { h = w / ratio }
            }
            var x: Float, y: Float
            if let list {
                let horizontal = list.get("FillDirection")?.asEnum == 0
                let pad = udim(list, "Padding")
                if horizontal {
                    x = rect.x + cursor; y = rect.y
                    cursor += w + pad.scale * rect.w + Float(pad.offset)
                    if list.get("VerticalAlignment")?.asEnum == 0 { y = rect.y + (rect.h - h) / 2 }
                } else {
                    x = rect.x; y = rect.y + cursor
                    cursor += h + pad.scale * rect.h + Float(pad.offset)
                    if list.get("HorizontalAlignment")?.asEnum == 0 { x = rect.x + (rect.w - w) / 2 }
                }
            } else if let grid {
                let cs = udim2(grid, "CellSize", UDim2(0, 100, 0, 100)), cp = udim2(grid, "CellPadding", UDim2(0, 5, 0, 5))
                w = cs.x.scale * rect.w + Float(cs.x.offset); h = cs.y.scale * rect.h + Float(cs.y.offset)
                let px = cp.x.scale * rect.w + Float(cp.x.offset), py = cp.y.scale * rect.h + Float(cp.y.offset)
                let perRow = max(1, Int((rect.w + px) / max(1, w + px)))
                x = rect.x + Float(idx % perRow) * (w + px); y = rect.y + Float(idx / perRow) * (h + py)
            } else {
                let pos = udim2(g, "Position", UDim2(0, 0, 0, 0))
                let anchor = g.get("AnchorPoint").flatMap { v -> Vector2? in if case .vector2(let a) = v { return a }; return nil } ?? .zero
                x = rect.x + pos.x.scale * rect.w + Float(pos.x.offset) - anchor.x * w
                y = rect.y + pos.y.scale * rect.h + Float(pos.y.offset) - anchor.y * h
            }
            if case .udim2(let off)? = g.get("__scrollOffset") { y -= Float(off.y.offset) }
            Gui.rects[ObjectIdentifier(g)] = (x, y, w, h)
            let z = baseZ + Int(num(g, "ZIndex", 1))
            out.append(item(g, x, y, w, h, clip, z, order))
            order += 1
            let clips = g.get("ClipsDescendants")?.asBool == true || g.className == "ScrollingFrame"
            let childClip = clips ? intersect(clip, (x, y, w, h)) : clip
            var inner = (x: x, y: y, w: w, h: h)
            if g.className == "ScrollingFrame" {
                let canvas = udim2(g, "CanvasSize", UDim2(0, 0, 2, 0))
                inner.h = max(h, canvas.y.scale * h + Float(canvas.y.offset))
                inner.w = max(w, canvas.x.scale * w + Float(canvas.x.offset))
                if case .vector2(let cp)? = g.get("CanvasPosition") { inner.x -= cp.x; inner.y -= cp.y }
            }
            children(g, inner, childClip, z, &out, &order)
        }
    }

    private static func intersect(_ a: (x: Float, y: Float, w: Float, h: Float)?, _ b: (x: Float, y: Float, w: Float, h: Float)) -> (x: Float, y: Float, w: Float, h: Float) {
        guard let a else { return b }
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y), x1 = min(a.x + a.w, b.x + b.w), y1 = min(a.y + a.h, b.y + b.h)
        return (x0, y0, max(0, x1 - x0), max(0, y1 - y0))
    }

    private static func item(_ g: Instance, _ x: Float, _ y: Float, _ w: Float, _ h: Float,
                             _ clip: (x: Float, y: Float, w: Float, h: Float)?, _ z: Int, _ order: Int) -> GuiItem {
        let kind: GuiItem.Kind
        switch g.className {
        case "TextLabel": kind = .text
        case "TextButton": kind = .textButton
        case "TextBox": kind = .textBox
        case "ImageLabel": kind = .image
        case "ImageButton": kind = .imageButton
        case "ScrollingFrame": kind = .scroll
        default: kind = .frame
        }
        let corner = g.findFirstChildOfClass("UICorner").map { c -> Float in
            let u = udim(c, "CornerRadius"); return u.scale * min(w, h) + Float(u.offset)
        } ?? 0
        let stroke = g.findFirstChildOfClass("UIStroke").map { s in
            (color(s, "Color", Color3(0, 0, 0)), num(s, "Thickness", 1), 1 - num(s, "Transparency", 0))
        }
        var bold = false
        var fontName = "SourceSans"
        if case .font(let f)? = g.get("FontFace") {
            bold = f.weight >= 600
            fontName = (f.family as NSString).lastPathComponent.replacingOccurrences(of: ".json", with: "")
        } else if let e = g.get("Font")?.asEnum, let n = Enums.itemName("Font", Int(e)) {
            fontName = n; bold = n.hasSuffix("Bold")
        }
        var bgAlpha = 1 - num(g, "BackgroundTransparency", 0)
        if g.className == "TextLabel" || g.className == "ImageLabel" { bgAlpha = 1 - num(g, "BackgroundTransparency", 0) }
        var it = GuiItem(
            inst: g, kind: kind, x: x, y: y, w: w, h: h, clip: clip,
            background: color(g, "BackgroundColor3", Color3(1, 1, 1)), backgroundAlpha: bgAlpha,
            cornerRadius: corner, stroke: stroke,
            text: g.get("Text")?.asString ?? "", textColor: color(g, "TextColor3", Color3(0, 0, 0)),
            textAlpha: 1 - num(g, "TextTransparency", 0), textSize: num(g, "TextSize", 14),
            textScaled: g.get("TextScaled")?.asBool == true, textWrapped: g.get("TextWrapped")?.asBool == true,
            xAlign: Int(g.get("TextXAlignment")?.asEnum ?? 2), yAlign: Int(g.get("TextYAlignment")?.asEnum ?? 1),
            bold: bold, font: fontName,
            image: g.get("Image")?.description ?? "", imageColor: color(g, "ImageColor3", Color3(1, 1, 1)),
            imageAlpha: 1 - num(g, "ImageTransparency", 0), rotation: num(g, "Rotation", 0), zIndex: z, order: order)
        if g.className == "TextBox", it.text.isEmpty, let ph = g.get("PlaceholderText")?.asString {
            it.text = ph
            it.textColor = color(g, "PlaceholderColor3", Color3(0.7, 0.7, 0.7))
        }
        return it
    }
}

extension Gui {
    /// Absolute rects from the last layout pass (AbsolutePosition / AbsoluteSize).
    static var rects: [ObjectIdentifier: (x: Float, y: Float, w: Float, h: Float)] = [:]
}
