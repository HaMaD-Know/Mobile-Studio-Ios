import SwiftUI
import StudioCore
import StudioScript

/// On-screen controls while playing (port of ui/PlayHud.kt): thumbstick, jump, prompt, tools,
/// leaderstats, context-action buttons and Stop.
struct PlayHUD: View {
    @ObservedObject var store: StudioStore
    let play: PlaySession

    var body: some View {
        let _ = store.hudTick
        ZStack {
            VStack {
                HStack(alignment: .top) {
                    Button { store.stopPlay() } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.headline)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.red.opacity(0.85), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    leaderstats
                }
                .padding(12)
                Spacer()
            }
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    Thumbstick { v in play.moveInput = Vector2(Float(v.x), Float(-v.y)) }
                        .frame(width: 150, height: 150)
                        .padding(.leading, 20)
                    Spacer()
                    toolbar
                    Spacer()
                    VStack(spacing: 14) {
                        ForEach(play.actions.keys.sorted(), id: \.self) { name in
                            Button(play.actions[name]?.title ?? name) { }
                                .simultaneousGesture(DragGesture(minimumDistance: 0)
                                    .onChanged { _ in play.pressAction(name, began: true) }
                                    .onEnded { _ in play.pressAction(name, began: false) })
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        if let prompt = play.nearestPrompt {
                            Button { play.triggerPrompt() } label: {
                                VStack(spacing: 2) {
                                    Text(prompt.get("ActionText")?.asString ?? "Interact").font(.headline)
                                    if let o = prompt.get("ObjectText")?.asString, !o.isEmpty { Text(o).font(.caption) }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .foregroundStyle(.primary)
                        }
                        Button { play.requestJump() } label: {
                            Image(systemName: "arrow.up").font(.system(size: 30, weight: .bold))
                                .frame(width: 84, height: 84)
                                .background(.white.opacity(0.25), in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 2))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.trailing, 24)
                }
                .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder private var leaderstats: some View {
        let stats = play.leaderstats()
        if !stats.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text("Player").bold(); ForEach(stats, id: \.0) { Text($0.0).bold().frame(minWidth: 50) } }
                HStack { Text(play.player?.name ?? ""); ForEach(stats, id: \.0) { Text($0.1).frame(minWidth: 50) } }
            }
            .font(.caption)
            .padding(8)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder private var toolbar: some View {
        let tools = play.backpackTools()
        if !tools.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(tools.enumerated()), id: \.offset) { i, t in
                    Button { play.toggleTool(t) } label: {
                        VStack(spacing: 2) {
                            Text("\(i + 1)").font(.caption2)
                            Text(t.name).font(.caption).lineLimit(1)
                        }
                        .frame(width: 64, height: 56)
                        .background(t.parent === play.character ? Color.accentColor.opacity(0.6) : Color.black.opacity(0.45),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                    }
                }
            }
        }
    }
}

/// Virtual thumbstick: reports a vector in -1...1 (y down).
struct Thumbstick: View {
    var onChange: (CGPoint) -> Void
    @State private var knob = CGPoint.zero

    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            ZStack {
                Circle().fill(.white.opacity(0.18)).overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 2))
                Circle().fill(.white.opacity(0.55)).frame(width: r * 0.8, height: r * 0.8)
                    .offset(x: knob.x * r * 0.6, y: knob.y * r * 0.6)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    var v = CGPoint(x: (g.location.x - r) / (r * 0.6), y: (g.location.y - r) / (r * 0.6))
                    let len = (v.x * v.x + v.y * v.y).squareRoot()
                    if len > 1 { v = CGPoint(x: v.x / len, y: v.y / len) }
                    knob = v
                    onChange(v)
                }
                .onEnded { _ in knob = .zero; onChange(.zero) })
        }
    }
}
