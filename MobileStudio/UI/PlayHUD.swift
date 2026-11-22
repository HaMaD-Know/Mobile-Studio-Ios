import SwiftUI
import StudioCore
import StudioScript

/// On-screen controls while playing (port of ui/PlayHud.kt): thumbstick, jump, prompt, tools,
/// leaderstats, context-action buttons and Stop.
struct PlayHUD: View {
    @ObservedObject var store: StudioStore
    let play: PlaySession
    @State private var showChat = true
    @State private var chatText = ""

    var body: some View {
        let _ = store.hudTick
        ZStack {
            if play.shiftLock {
                ZStack {
                    Circle().stroke(.white.opacity(0.85), lineWidth: 2).frame(width: 18, height: 18)
                    Circle().fill(.white.opacity(0.85)).frame(width: 4, height: 4)
                }
                .allowsHitTesting(false)
            }
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        topPill
                        if showChat { chatBox }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        healthBar
                        leaderstats
                    }
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
                            Image(systemName: "chevron.up").font(.system(size: 34, weight: .semibold))
                                .frame(width: 92, height: 92)
                                .background(Color.black.opacity(0.3), in: Circle())
                                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 3))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.trailing, 24)
                }
                .padding(.bottom, 24)
            }
        }
    }

    /// Roblox-style menu / chat / emotes / more pill.
    private var topPill: some View {
        HStack(spacing: 16) {
            Menu {
                Button("Reset Character", systemImage: "arrow.counterclockwise") {
                    if let p = play.player { play.respawn(p) }
                }
                Button(play.shiftLock ? "Disable Shift Lock" : "Enable Shift Lock", systemImage: "scope") {
                    play.shiftLock.toggle()
                }
                Divider()
                Button("Stop Playtest", systemImage: "stop.fill", role: .destructive) { store.stopPlay() }
            } label: {
                Image(systemName: "square.fill").font(.system(size: 22)).rotationEffect(.degrees(15)).foregroundStyle(.white)
            }
            Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 26)
            Button { showChat.toggle() } label: {
                Image(systemName: "bubble.left").font(.system(size: 21)).foregroundStyle(showChat ? .white : .white.opacity(0.6))
            }
            if play.character != nil {
                Menu {
                    ForEach(DefaultAnimate.emoteNames, id: \.key) { emote in
                        Button(emote.title) { play.sendChat("/e " + emote.key) }
                    }
                } label: {
                    Image(systemName: "figure.wave").font(.system(size: 20)).foregroundStyle(.white)
                }
            }
            Menu {
                Button(showChat ? "Hide Chat" : "Show Chat") { showChat.toggle() }
                Button(play.shiftLock ? "Disable Shift Lock" : "Enable Shift Lock") { play.shiftLock.toggle() }
                Button("Reset Character") { if let p = play.player { play.respawn(p) } }
                Divider()
                Button("Stop Playtest", role: .destructive) { store.stopPlay() }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 21, weight: .bold)).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 18).frame(height: 50)
        .background(Color.black.opacity(0.55), in: Capsule())
    }

    @ViewBuilder private var healthBar: some View {
        if let hum = play.character?.findFirstChildOfClass("Humanoid") {
            let hp = hum.get("Health_XML")?.asFloat ?? hum.get("Health")?.asFloat ?? 100
            let maxHp = max(hum.get("MaxHealth")?.asFloat ?? 100, 1)
            if hp < maxHp {
                let frac = max(0, min(1, CGFloat(hp / maxHp)))
                let barColor: Color = frac > 0.5 ? Color(red: 0.17, green: 0.82, blue: 0.36)
                    : (frac > 0.25 ? Color(red: 0.96, green: 0.77, blue: 0.09) : Color(red: 0.92, green: 0.26, blue: 0.26))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.5))
                    Capsule().fill(barColor).frame(width: 120 * frac)
                }
                .frame(width: 120, height: 8)
            }
        }
    }

    private var chatBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(play.chatLines.suffix(6).enumerated()), id: \.offset) { _, line in
                (Text(line.0.isEmpty ? "" : line.0 + ": ").bold() + Text(line.1))
                    .font(.system(size: 13)).foregroundStyle(.white).lineLimit(2)
            }
            TextField("", text: $chatText, prompt: Text("Chat '/?' or '/help' for a list of chat commands").foregroundStyle(.white.opacity(0.6)))
                .font(.system(size: 13)).foregroundStyle(.white)
                .onSubmit {
                    let t = chatText.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { play.sendChat(t) }
                    chatText = ""
                }
                .padding(.horizontal, 10).frame(height: 34)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(10)
        .frame(width: 330, alignment: .leading)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
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
