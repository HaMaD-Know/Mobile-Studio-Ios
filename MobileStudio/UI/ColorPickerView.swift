import SwiftUI
import StudioCore

/// Multi-mode Roblox color picker (port of ui/ColorPickerView.kt + ui/ColorPicker.kt):
/// Wheel + Brightness bar, RGB/HSB/Gray sliders + Hex input, BrickColor Palette, and 48 Pencils,
/// with original/new comparison and saved swatches persisted in UserDefaults.
struct StudioColorPickerSheet: View {
    let title: String
    let initial: Color3
    let onCommit: (Color3) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Int = UserDefaults.standard.integer(forKey: "colorPicker.mode")
    @State private var sliderMode: Int = UserDefaults.standard.integer(forKey: "colorPicker.sliders")
    @State private var hue: Double = 0
    @State private var sat: Double = 0
    @State private var bri: Double = 1
    @State private var r: Int = 255
    @State private var g: Int = 255
    @State private var b: Int = 255
    @State private var hexText: String = "FFFFFF"
    @State private var pickedName: String = ""
    @State private var saved: [UInt32] = Self.loadSaved()

    private static let savedKey = "colorPicker.saved"

    private static let pencils: [(String, UInt32)] = [
        ("Cayenne", 0x941100), ("Mocha", 0x945200), ("Asparagus", 0x929000), ("Fern", 0x4F8F00),
        ("Clover", 0x008F00), ("Moss", 0x009051), ("Teal", 0x009193), ("Ocean", 0x005493),
        ("Midnight", 0x011993), ("Eggplant", 0x531B93), ("Plum", 0x942193), ("Maroon", 0x941751),
        ("Maraschino", 0xFF2600), ("Tangerine", 0xFF9300), ("Lemon", 0xFFFB00), ("Lime", 0x8EFA00),
        ("Spring", 0x00F900), ("Sea Foam", 0x00FA92), ("Turquoise", 0x00FDFF), ("Aqua", 0x0096FF),
        ("Blueberry", 0x0433FF), ("Grape", 0x9437FF), ("Magenta", 0xFF40FF), ("Strawberry", 0xFF2F92),
        ("Salmon", 0xFF7E79), ("Cantaloupe", 0xFFD479), ("Banana", 0xFFFC79), ("Honeydew", 0xD4FB79),
        ("Flora", 0x73FA79), ("Spindrift", 0x73FCD6), ("Ice", 0x73FDFF), ("Sky", 0x76D6FF),
        ("Orchid", 0x7A81FF), ("Lavender", 0xD783FF), ("Bubblegum", 0xFF85FF), ("Carnation", 0xFF8AD8),
        ("Licorice", 0x000000), ("Lead", 0x212121), ("Tungsten", 0x424242), ("Iron", 0x5E5E5E),
        ("Steel", 0x797979), ("Tin", 0x919191), ("Nickel", 0x929292), ("Aluminum", 0xA9A9A9),
        ("Magnesium", 0xC0C0C0), ("Silver", 0xD6D6D6), ("Mercury", 0xEBEBEB), ("Snow", 0xFFFFFF),
    ]

    init(title: String = "Color", initial: Color3, onCommit: @escaping (Color3) -> Void) {
        self.title = title
        self.initial = initial
        self.onCommit = onCommit
    }

    private var currentColor3: Color3 { Color3(Float(r) / 255, Float(g) / 255, Float(b) / 255) }
    private var currentUInt: UInt32 { (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b) }
    private var currentSwiftColor: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
    private var initialSwiftColor: Color { Color(red: Double(initial.r), green: Double(initial.g), blue: Double(initial.b)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    modeBar
                    comparisonBar
                    Text(infoLine)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Th.dim)
                        .multilineTextAlignment(.center)
                    modeBody
                    savedStrip
                }
                .padding(14)
            }
            .background(Th.panel)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { onCommit(currentColor3); dismiss() }.bold()
                }
            }
            .onAppear { setRGB(Int((initial.r * 255).rounded()), Int((initial.g * 255).rounded()), Int((initial.b * 255).rounded())) }
        }
        .presentationDetents([.medium, .large])
    }

    private var infoLine: String {
        let nearest = BrickColors.name(BrickColors.closest(currentColor3))
        return String(format: "#%06X  ·  RGB %d, %d, %d  ·  nearest: %@", currentUInt, r, g, b, nearest)
    }

    // MARK: mode switcher

    private var modeBar: some View {
        HStack(spacing: 4) {
            ForEach([(0, "Wheel"), (1, "Sliders"), (2, "Palette"), (3, "Pencils")], id: \.0) { idx, label in
                Button {
                    mode = idx
                    UserDefaults.standard.set(idx, forKey: "colorPicker.mode")
                } label: {
                    Text(label)
                        .font(.system(size: 13, weight: mode == idx ? .semibold : .regular))
                        .foregroundStyle(mode == idx ? .white : Th.dim)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(mode == idx ? Th.accent : Th.input, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: original vs new comparison

    private var comparisonBar: some View {
        HStack(spacing: 0) {
            Button {
                setRGB(Int((initial.r * 255).rounded()), Int((initial.g * 255).rounded()), Int((initial.b * 255).rounded()))
            } label: {
                initialSwiftColor
                    .overlay(alignment: .bottomLeading) {
                        Text("Original").font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white).shadow(color: .black.opacity(0.7), radius: 2)
                            .padding(4)
                    }
            }
            .buttonStyle(.plain)
            currentSwiftColor
                .overlay(alignment: .bottomTrailing) {
                    Text("New").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white).shadow(color: .black.opacity(0.7), radius: 2)
                        .padding(4)
                }
        }
        .frame(height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Th.border, lineWidth: 1))
    }

    // MARK: mode pages

    @ViewBuilder private var modeBody: some View {
        switch mode {
        case 0: wheelPage
        case 1: slidersPage
        case 2: palettePage
        default: pencilsPage
        }
    }

    private var wheelPage: some View {
        HStack(spacing: 16) {
            ColorWheelView(hue: $hue, sat: $sat, bri: bri) { syncFromHSV() }
                .frame(width: 184, height: 184)
            BrightnessBarView(hue: hue, sat: sat, bri: $bri) { syncFromHSV() }
                .frame(width: 28, height: 184)
        }
        .padding(.vertical, 4)
    }

    private var slidersPage: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach([(0, "RGB"), (1, "HSB"), (2, "Gray")], id: \.0) { idx, label in
                    Button {
                        sliderMode = idx
                        UserDefaults.standard.set(idx, forKey: "colorPicker.sliders")
                    } label: {
                        Text(label).font(.system(size: 12, weight: sliderMode == idx ? .semibold : .regular))
                            .foregroundStyle(sliderMode == idx ? Th.text : Th.dim)
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(sliderMode == idx ? Th.hover : Th.input, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
            switch sliderMode {
            case 0:
                GradSliderRow(label: "Red", value: Double(r), max: 255,
                              stops: [Color(red: 0, green: Double(g) / 255, blue: Double(b) / 255),
                                      Color(red: 1, green: Double(g) / 255, blue: Double(b) / 255)]) {
                    setRGB(Int($0.rounded()), g, b)
                }
                GradSliderRow(label: "Green", value: Double(g), max: 255,
                              stops: [Color(red: Double(r) / 255, green: 0, blue: Double(b) / 255),
                                      Color(red: Double(r) / 255, green: 1, blue: Double(b) / 255)]) {
                    setRGB(r, Int($0.rounded()), b)
                }
                GradSliderRow(label: "Blue", value: Double(b), max: 255,
                              stops: [Color(red: Double(r) / 255, green: Double(g) / 255, blue: 0),
                                      Color(red: Double(r) / 255, green: Double(g) / 255, blue: 1)]) {
                    setRGB(r, g, Int($0.rounded()))
                }
                hexRow
            case 1:
                GradSliderRow(label: "Hue", value: hue, max: 360,
                              stops: (0...6).map { Color(hue: Double($0) / 6.0, saturation: 1, brightness: 1) }) {
                    hue = $0; syncFromHSV()
                }
                GradSliderRow(label: "Saturation", value: sat * 100, max: 100,
                              stops: [Color(hue: hue / 360, saturation: 0, brightness: bri),
                                      Color(hue: hue / 360, saturation: 1, brightness: bri)]) {
                    sat = $0 / 100; syncFromHSV()
                }
                GradSliderRow(label: "Brightness", value: bri * 100, max: 100,
                              stops: [.black, Color(hue: hue / 360, saturation: sat, brightness: 1)]) {
                    bri = $0 / 100; syncFromHSV()
                }
            default:
                let grayPct = (Double(r) * 0.299 + Double(g) * 0.587 + Double(b) * 0.114) / 2.55
                GradSliderRow(label: "Brightness", value: grayPct, max: 100, stops: [.black, .white]) {
                    let v = max(0, min(255, Int(($0 * 2.55).rounded())))
                    setRGB(v, v, v)
                }
            }
        }
    }

    private var hexRow: some View {
        HStack(spacing: 8) {
            Text("Hex #").font(.system(size: 13)).foregroundStyle(Th.dim)
            TextField("FFFFFF", text: $hexText)
                .font(.system(size: 13, design: .monospaced))
                .textInputAutocapitalization(.characters).autocorrectionDisabled()
                .onSubmit { applyHex(hexText) }
                .onChange(of: hexText) { _, val in
                    let clean = val.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                    if clean.count == 6, let v = UInt32(clean, radix: 16) {
                        setUInt(v, updateHex: false)
                    }
                }
                .studioField()
                .frame(width: 110)
            Spacer()
        }
        .padding(.top, 2)
    }

    private var palettePage: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 32), spacing: 4)], spacing: 4) {
                ForEach(BrickColors.all, id: \.self) { n in
                    let c = BrickColorV(Int32(n)).color
                    Button {
                        setRGB(Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
                        pickedName = BrickColors.name(n)
                    } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b)))
                            .frame(height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Th.border, lineWidth: 0.7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(BrickColors.name(n))
                }
            }
            if !pickedName.isEmpty {
                Text(pickedName).font(.system(size: 12)).foregroundStyle(Th.text)
            }
        }
    }

    private var pencilsPage: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 12), spacing: 4) {
                ForEach(Array(Self.pencils.enumerated()), id: \.offset) { _, p in
                    let col = colorFromUInt(p.1)
                    Button {
                        setUInt(p.1)
                        pickedName = p.0
                    } label: {
                        PencilShapeView(color: col)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(p.0)
                }
            }
            if !pickedName.isEmpty {
                Text(pickedName).font(.system(size: 12)).foregroundStyle(Th.text)
            }
        }
    }

    // MARK: saved swatches

    private var savedStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved Colors").font(.system(size: 11, weight: .semibold)).foregroundStyle(Th.dim)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button {
                        let c = currentUInt
                        if !saved.contains(c) {
                            saved.insert(c, at: 0)
                            if saved.count > 30 { saved = Array(saved.prefix(30)) }
                            Self.storeSaved(saved)
                        }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(Th.text)
                            .frame(width: 28, height: 28)
                            .background(Th.input, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Th.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    ForEach(saved, id: \.self) { c in
                        Button { setUInt(c) } label: {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(colorFromUInt(c))
                                .frame(width: 28, height: 28)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(c == currentUInt ? Color.white : Th.border, lineWidth: c == currentUInt ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove", role: .destructive) {
                                saved.removeAll { $0 == c }
                                Self.storeSaved(saved)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: color conversions

    private func setRGB(_ nr: Int, _ ng: Int, _ nb: Int, updateHex: Bool = true) {
        r = max(0, min(255, nr)); g = max(0, min(255, ng)); b = max(0, min(255, nb))
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let mx = max(rf, max(gf, bf)), mn = min(rf, min(gf, bf)), d = mx - mn
        let v = mx
        let s = mx > 0.0001 ? d / mx : 0
        if s > 0.001 && v > 0.001 {
            var h: Double = 0
            if d > 0.0001 {
                if mx == rf { h = 60 * (((gf - bf) / d).truncatingRemainder(dividingBy: 6)) }
                else if mx == gf { h = 60 * ((bf - rf) / d + 2) }
                else { h = 60 * ((rf - gf) / d + 4) }
                if h < 0 { h += 360 }
            }
            hue = h
        }
        if v > 0.001 { sat = s }
        bri = v
        if updateHex { hexText = String(format: "%06X", currentUInt) }
    }

    private func syncFromHSV() {
        let h = max(0, min(360, hue)), s = max(0, min(1, sat)), v = max(0, min(1, bri))
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (rp, gp, bp): (Double, Double, Double)
        switch h {
        case ..<60: (rp, gp, bp) = (c, x, 0)
        case ..<120: (rp, gp, bp) = (x, c, 0)
        case ..<180: (rp, gp, bp) = (0, c, x)
        case ..<240: (rp, gp, bp) = (0, x, c)
        case ..<300: (rp, gp, bp) = (x, 0, c)
        default: (rp, gp, bp) = (c, 0, x)
        }
        r = max(0, min(255, Int(((rp + m) * 255).rounded())))
        g = max(0, min(255, Int(((gp + m) * 255).rounded())))
        b = max(0, min(255, Int(((bp + m) * 255).rounded())))
        hexText = String(format: "%06X", currentUInt)
    }

    private func setUInt(_ v: UInt32, updateHex: Bool = true) {
        setRGB(Int((v >> 16) & 0xFF), Int((v >> 8) & 0xFF), Int(v & 0xFF), updateHex: updateHex)
    }

    private func applyHex(_ s: String) {
        let clean = s.trimmingCharacters(in: CharacterSet(charactersIn: "# \t\n"))
        if let v = UInt32(clean, radix: 16), clean.count == 6 { setUInt(v) }
        else { hexText = String(format: "%06X", currentUInt) }
    }

    private func colorFromUInt(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    private static func loadSaved() -> [UInt32] {
        let s = UserDefaults.standard.string(forKey: savedKey) ?? ""
        return s.split(separator: ",").compactMap { UInt32($0, radix: 16) }
    }

    private static func storeSaved(_ list: [UInt32]) {
        UserDefaults.standard.set(list.map { String(format: "%06X", $0) }.joined(separator: ","), forKey: savedKey)
    }
}

// MARK: - Subviews

private struct ColorWheelView: View {
    @Binding var hue: Double
    @Binding var sat: Double
    let bri: Double
    let onChange: () -> Void

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let rad = hue * .pi / 180
            let kx = center.x + CGFloat(cos(rad) * sat) * radius
            let ky = center.y + CGFloat(sin(rad) * sat) * radius
            ZStack {
                Circle()
                    .fill(AngularGradient(gradient: Gradient(colors: (0...12).map {
                        Color(hue: Double($0) / 12.0, saturation: 1, brightness: 1)
                    }), center: .center))
                Circle()
                    .fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: radius))
                if bri < 0.999 {
                    Circle().fill(Color.black.opacity(1 - bri))
                }
                Circle().stroke(Th.border, lineWidth: 1)
                Circle()
                    .stroke(Color.white, lineWidth: 2.5)
                    .background(Circle().stroke(Color.black.opacity(0.6), lineWidth: 4.5))
                    .frame(width: 14, height: 14)
                    .position(x: kx, y: ky)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let dx = Double(g.location.x - center.x), dy = Double(g.location.y - center.y)
                var deg = atan2(dy, dx) * 180 / .pi
                if deg < 0 { deg += 360 }
                hue = deg
                sat = min(1, hypot(dx, dy) / Double(max(radius, 1)))
                onChange()
            })
        }
    }
}

private struct BrightnessBarView: View {
    let hue: Double
    let sat: Double
    @Binding var bri: Double
    let onChange: () -> Void

    var body: some View {
        GeometryReader { geo in
            let topColor = Color(hue: hue / 360, saturation: sat, brightness: 1)
            let y = CGFloat(1 - max(0, min(1, bri))) * geo.size.height
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [topColor, .black], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Th.border, lineWidth: 1))
                RoundedRectangle(cornerRadius: 3)
                    .stroke(.white, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.6), lineWidth: 3.5))
                    .frame(height: 8)
                    .offset(y: max(0, min(geo.size.height - 8, y - 4)))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                bri = max(0, min(1, 1 - Double(g.location.y / max(geo.size.height, 1))))
                onChange()
            })
        }
    }
}

private struct GradSliderRow: View {
    let label: String
    let value: Double
    let max: Double
    let stops: [Color]
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Th.dim).frame(width: 66, alignment: .leading)
            GeometryReader { geo in
                let frac = Swift.max(0, Swift.min(1, value / Swift.max(max, 1)))
                let x = CGFloat(frac) * geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 16)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Th.border, lineWidth: 1))
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 1.5))
                        .frame(width: 18, height: 18)
                        .offset(x: Swift.max(0, Swift.min(geo.size.width - 18, x - 9)))
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let f = Swift.max(0, Swift.min(1, Double(g.location.x / Swift.max(geo.size.width, 1))))
                    onChange(f * max)
                })
            }
            .frame(height: 24)
            Text("\(Int(value.rounded()))")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Th.text)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

private struct PencilShapeView: View {
    let color: Color
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let tipH = h * 0.32
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: w / 2, y: 0))
                    p.addLine(to: CGPoint(x: w, y: tipH))
                    p.addLine(to: CGPoint(x: 0, y: tipH))
                    p.closeSubpath()
                }
                .fill(Color(red: 0.90, green: 0.78, blue: 0.62))
                Path { p in
                    p.move(to: CGPoint(x: w / 2, y: 0))
                    p.addLine(to: CGPoint(x: w * 0.68, y: tipH * 0.42))
                    p.addLine(to: CGPoint(x: w * 0.32, y: tipH * 0.42))
                    p.closeSubpath()
                }
                .fill(color)
                Path { p in
                    p.addRect(CGRect(x: 0, y: tipH, width: w, height: h - tipH))
                }
                .fill(color)
                Path { p in
                    p.addRect(CGRect(x: 0, y: tipH, width: w * 0.25, height: h - tipH))
                }
                .fill(Color.white.opacity(0.2))
                Path { p in
                    p.addRect(CGRect(x: w * 0.75, y: tipH, width: w * 0.25, height: h - tipH))
                }
                .fill(Color.black.opacity(0.2))
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}
