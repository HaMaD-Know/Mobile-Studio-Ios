import SwiftUI

// Building blocks of the Studio chrome (port of ui/Ui.kt helpers: tool, stack, group, header, divider).

/// Large ribbon button: icon over label, accent background when selected.
struct RibbonButton: View {
    let icon: String
    var tint: Color? = nil
    let label: String
    var selected = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RibbonLabel(icon: icon, tint: tint, label: label, selected: selected)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// Ribbon button that opens a menu.
struct RibbonMenu<Items: View>: View {
    let icon: String
    var tint: Color? = nil
    let label: String
    @ViewBuilder var items: Items

    var body: some View {
        Menu { items } label: { RibbonLabel(icon: icon, tint: tint, label: label, selected: false) }
            .menuStyle(.button)
            .buttonStyle(.plain)
    }
}

struct RibbonLabel: View {
    let icon: String
    var tint: Color?
    let label: String
    var selected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 21))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(selected ? .white : (tint ?? Th.text))
                .frame(height: 26)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(selected ? .white : Th.text)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 7)
        .frame(minWidth: 50, minHeight: 54)
        .background(selected ? Th.accent : .clear, in: RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
    }
}

/// Small stacked ribbon button (Copy / Cut / Duplicate).
struct RibbonSmallButton: View {
    let icon: String
    var tint: Color? = nil
    let label: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12)).symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint ?? Th.text).frame(width: 16)
                Text(label).font(.system(size: 13)).foregroundStyle(Th.text).fixedSize()
            }
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// A captioned ribbon group with a separator on its right.
struct RibbonGroup<Content: View>: View {
    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                HStack(alignment: .center, spacing: 2) { content }
                    .frame(height: 58)
                Text(caption).font(.system(size: 11)).foregroundStyle(Th.dim).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 6)
            Rectangle().fill(Th.border).frame(width: 1).padding(.vertical, 8)
        }
    }
}

/// Android-style checkbox (Ui.CheckBoxDrawable).
struct StudioCheckbox: View {
    @Binding var isOn: Bool
    var label: String? = nil

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2).fill(isOn ? Th.accent : Th.input)
                    RoundedRectangle(cornerRadius: 2).stroke(isOn ? Th.accent : Color(argb: -7697782), lineWidth: 1)
                    if isOn { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                }
                .frame(width: 18, height: 18)
                if let label { Text(label).font(.system(size: 13)).foregroundStyle(Th.text).fixedSize() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Dock panel title bar: grip, icon, title, optional subtitle, extra buttons, close.
struct PanelHeader<Trailing: View>: View {
    let icon: String
    var tint: Color = Th.text
    let title: String
    var subtitle: String? = nil
    var onClose: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.grid.2x2.fill").font(.system(size: 7)).foregroundStyle(Th.dim)
            Image(systemName: icon).font(.system(size: 14)).symbolRenderingMode(.hierarchical).foregroundStyle(tint)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Th.text).lineLimit(1).fixedSize()
            if let subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Th.dim).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            trailing
            if let onClose {
                PanelIconButton(icon: "xmark", action: onClose)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Th.header)
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(icon: String, tint: Color = Th.text, title: String, subtitle: String? = nil, onClose: (() -> Void)? = nil) {
        self.init(icon: icon, tint: tint, title: title, subtitle: subtitle, onClose: onClose) { EmptyView() }
    }
}

struct PanelIconButton: View {
    let icon: String
    var tint: Color = Th.text
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15)).symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Drag bar between two stacked panels; `fraction` is the share of `total` above it.
struct HSplitter: View {
    @Binding var fraction: Double
    let total: CGFloat
    @State private var start: Double?

    var body: some View {
        ZStack {
            Th.border
            HStack(spacing: 3) { ForEach(0..<5, id: \.self) { _ in Circle().fill(Th.dim).frame(width: 3, height: 3) } }
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { g in
                if start == nil { start = fraction }
                fraction = min(0.88, max(0.12, start! + Double(g.translation.height / max(total, 1))))
            }
            .onEnded { _ in start = nil })
    }
}

/// Drag bar between dock columns; `width` grows when dragged towards `growsRight`.
struct VSplitter: View {
    @Binding var width: Double
    var growsLeft: Bool
    var range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        ZStack {
            Th.border
            VStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Th.dim).frame(width: 3, height: 3) } }
        }
        .frame(width: 10)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { g in
                if start == nil { start = width }
                let d = Double(g.translation.width)
                width = min(range.upperBound, max(range.lowerBound, start! + (growsLeft ? -d : d)))
            }
            .onEnded { _ in start = nil })
    }
}

/// Themed text field look (Ui.input).
struct StudioFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 14))
            .foregroundStyle(Th.text)
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .background(Th.input, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Th.border, lineWidth: 1))
    }
}

extension View {
    func studioField() -> some View { modifier(StudioFieldStyle()) }
}

/// Small rounded pill (filter chips, "v2.0" badge).
struct Chip: View {
    let label: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 14))
                .foregroundStyle(selected ? .white : Th.text)
                .padding(.horizontal, 14).frame(height: 30)
                .background(selected ? Th.accent : Th.hover, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Frames-per-second counter fed by the renderer.
final class FPSMeter: ObservableObject {
    static let shared = FPSMeter()
    @Published private(set) var fps = 0
    private var frames = 0
    private var since = CACurrentMediaTime()
    func frame() {
        frames += 1
        let now = CACurrentMediaTime()
        if now - since >= 1 {
            fps = Int((Double(frames) / (now - since)).rounded())
            frames = 0
            since = now
        }
    }
}

struct FPSLabel: View {
    @ObservedObject var meter = FPSMeter.shared
    var body: some View {
        Text("\(meter.fps) FPS").font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
            .shadow(color: .black.opacity(0.5), radius: 1)
    }
}

/// Theme-coloured transient message (Studio.toast).
struct ToastView: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 14)).foregroundStyle(Th.text)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Th.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Th.border))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }
}
