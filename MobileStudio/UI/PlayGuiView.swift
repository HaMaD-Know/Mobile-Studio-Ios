import SwiftUI
import StudioCore
import StudioScript

/// Draws the game's ScreenGuis / BillboardGuis (port of ui/GuiOverlay.kt) and routes taps on
/// buttons and text boxes back to scripts.
struct PlayGuiView: View {
    @ObservedObject var store: StudioStore
    let play: PlaySession

    var body: some View {
        let _ = store.hudTick
        let items = play.layoutGui()
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                GuiItemView(item: it, play: .play(play))
                    .frame(width: CGFloat(max(0, it.w)), height: CGFloat(max(0, it.h)))
                    .rotationEffect(.degrees(Double(it.rotation)))
                    .position(x: CGFloat(it.x + it.w / 2), y: CGFloat(it.y + it.h / 2))
                    .mask(alignment: .topLeading) { clipMask(it) }
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private func clipMask(_ it: GuiItem) -> some View {
        if let c = it.clip {
            Rectangle()
                .frame(width: CGFloat(c.w), height: CGFloat(c.h))
                .offset(x: CGFloat(c.x - it.x), y: CGFloat(c.y - it.y))
                .frame(width: CGFloat(max(1, it.w)), height: CGFloat(max(1, it.h)), alignment: .topLeading)
        } else {
            Rectangle()
        }
    }
}

private extension Color3 {
    func color(_ a: Float = 1) -> Color { Color(red: Double(r), green: Double(g), blue: Double(b)).opacity(Double(max(0, min(1, a)))) }
}

/// Input callbacks for GUI items (Play session or plugin widgets).
struct GuiActions {
    var press: (Instance, Bool) -> Void = { _, _ in }
    var activate: (Instance) -> Void = { _ in }
    var text: (Instance, String) -> Void = { _, _ in }
    var focus: (Instance) -> Void = { _ in }
    var scroll: (Instance, Float, Float) -> Void = { _, _, _ in }

    static func play(_ p: PlaySession) -> GuiActions {
        GuiActions(press: { p.guiPress($0, down: $1) }, activate: { p.guiActivate($0) },
                   text: { p.guiText($0, $1, enter: true) }, focus: { p.guiFocus($0) },
                   scroll: { p.guiScroll($0, dx: $1, dy: $2) })
    }
}

struct GuiItemView: View {
    let item: GuiItem
    let play: GuiActions
    @State private var editing = ""
    @State private var image: UIImage?

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: CGFloat(item.cornerRadius)) }

    var body: some View {
        ZStack {
            shape.fill(item.background.color(item.backgroundAlpha))
            if let s = item.stroke { shape.stroke(s.0.color(s.2), lineWidth: CGFloat(s.1)) }
            switch item.kind {
            case .image, .imageButton:
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .colorMultiply(item.imageColor.color())
                        .opacity(Double(item.imageAlpha))
                        .clipShape(shape)
                }
            case .text, .textButton:
                textView(item.text)
            case .textBox:
                TextField("", text: $editing, onEditingChanged: { began in if began { play.focus(item.inst) } })
                    .onSubmit { play.text(item.inst, editing) }
                    .font(font)
                    .foregroundStyle(item.textColor.color(item.textAlpha))
                    .multilineTextAlignment(alignment)
                    .padding(.horizontal, 4)
                    .onAppear { editing = item.inst.get("Text")?.asString ?? "" }
            default:
                EmptyView()
            }
        }
        .contentShape(Rectangle())
        .allowsHitTesting(isInteractive)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !pressed { pressed = true; play.press(item.inst, true) } }
            .onEnded { g in
                pressed = false
                play.press(item.inst, false)
                if abs(g.translation.width) < 20 && abs(g.translation.height) < 20 { play.activate(item.inst) }
            }, including: isButton ? .all : .subviews)
        .gesture(DragGesture().onChanged { g in
            play.scroll(item.inst, Float(-g.velocity.width / 60), Float(-g.velocity.height / 60))
        }, including: item.kind == .scroll ? .all : .subviews)
        .onAppear(perform: loadImage)
        .onChange(of: item.image) { _, _ in loadImage() }
    }

    @State private var pressed = false

    private var isButton: Bool { item.kind == .textButton || item.kind == .imageButton }
    private var isInteractive: Bool {
        isButton || item.kind == .textBox || item.kind == .scroll || item.inst.get("Active")?.asBool == true
    }

    private var font: Font {
        let size = CGFloat(item.textScaled ? max(8, item.h * 0.7) : item.textSize)
        let design: Font.Design = item.font.contains("Code") || item.font.contains("Mono") || item.font.contains("Ubuntu") ? .monospaced : .default
        return .system(size: size, weight: item.bold ? .bold : .regular, design: design)
    }

    private var alignment: TextAlignment { item.xAlign == 0 ? .leading : (item.xAlign == 1 ? .trailing : .center) }

    private func textView(_ s: String) -> some View {
        let hAlign: Alignment = item.xAlign == 0 ? .leading : (item.xAlign == 1 ? .trailing : .center)
        let vAlign: Alignment = item.yAlign == 0 ? .top : (item.yAlign == 2 ? .bottom : .center)
        return Text(s)
            .font(font)
            .foregroundStyle(item.textColor.color(item.textAlpha))
            .multilineTextAlignment(alignment)
            .lineLimit(item.textWrapped ? nil : 1)
            .minimumScaleFactor(item.textScaled ? 0.2 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: hAlign.horizontal, vertical: vAlign.vertical))
            .padding(.horizontal, 2)
    }

    private func loadImage() {
        guard item.kind == .image || item.kind == .imageButton, !item.image.isEmpty else { image = nil; return }
        if let d = AssetCache.shared.data(for: item.image) { image = ImageDecoder.decode(d) ; return }
        AssetCache.shared.fetch(item.image) { url in
            if let url, let d = try? Data(contentsOf: url) { image = ImageDecoder.decode(d) }
        }
    }
}

/// Roblox image assets are usually PNG; Decals are sometimes XML wrappers pointing at the image.
enum ImageDecoder {
    static func decode(_ d: Data) -> UIImage? {
        if let img = UIImage(data: d) { return img }
        // Decal asset XML: <url>http://www.roblox.com/asset/?id=123</url>
        let s = String(decoding: d.prefix(4096), as: UTF8.self)
        if let r = s.range(of: "<url>"), let e = s.range(of: "</url>", range: r.upperBound..<s.endIndex) {
            let inner = String(s[r.upperBound..<e.lowerBound])
            AssetCache.shared.fetch(inner)
        }
        return nil
    }
}

/// Plugin dock widgets shown as floating panels in the editor.
struct PluginWidgetsView: View {
    @ObservedObject var store: StudioStore
    @State private var tick = 0
    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        let _ = tick
        if let host = store.pluginHost {
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(host.widgets(), id: \.self) { w in
                    let size = Vector2(300, 360)
                    VStack(spacing: 0) {
                        HStack {
                            Text(w.get("Title")?.asString ?? w.name).font(.caption.bold())
                            Spacer()
                            Button { w.set("Enabled", .bool(false)) } label: { Image(systemName: "xmark") }
                        }
                        .padding(6)
                        .background(.bar)
                        ZStack(alignment: .topLeading) {
                            Color(.systemBackground)
                            ForEach(Array(host.layout(widget: w, size: size).enumerated()), id: \.offset) { _, it in
                                GuiItemView(item: it, play: GuiActions(activate: { host.guiActivate($0) },
                                                                       text: { host.guiText($0, $1, enter: true) }))
                                    .frame(width: CGFloat(max(0, it.w)), height: CGFloat(max(0, it.h)))
                                    .position(x: CGFloat(it.x + it.w / 2), y: CGFloat(it.y + it.h / 2))
                            }
                        }
                        .frame(width: CGFloat(size.x), height: CGFloat(size.y))
                        .clipped()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 6)
                }
            }
            .padding(10)
            .onReceive(timer) { _ in tick &+= 1 }
        }
    }
}
