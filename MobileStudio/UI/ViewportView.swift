import SwiftUI
import MetalKit
import StudioCore
import StudioScript

/// The 3D viewport (port of ui/ViewportView.kt's edit-mode input):
/// tap = select, drag on a handle = move/scale/rotate, 1-finger drag = look around,
/// 2-finger drag = pan, pinch = fly forward/back, double-tap = focus selection.
struct ViewportView: UIViewRepresentable {
    @ObservedObject var store: StudioStore
    /// Stops drawing while a script tab covers the view.
    var paused: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = MTLCreateSystemDefaultDevice()
        v.colorPixelFormat = .bgra8Unorm
        v.depthStencilPixelFormat = .depth32Float
        v.sampleCount = 4
        v.preferredFramesPerSecond = 60
        v.clearColor = MTLClearColor(red: 0.6, green: 0.75, blue: 0.95, alpha: 1)
        if let d = v.device, let r = SceneRenderer(device: d) {
            r.store = store
            context.coordinator.renderer = r
            v.delegate = r
        }
        let c = context.coordinator
        c.view = v

        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let dbl = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        tap.require(toFail: dbl)
        let pan1 = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan1(_:)))
        pan1.maximumNumberOfTouches = 1
        let pan2 = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan2(_:)))
        pan2.minimumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        for g in [pan2, pinch] as [UIGestureRecognizer] { g.delegate = c }
        for g in [tap, dbl, pan1, pan2, pinch] as [UIGestureRecognizer] { v.addGestureRecognizer(g) }
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        if v.isPaused != paused { v.isPaused = paused }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let store: StudioStore
        var renderer: SceneRenderer?
        weak var view: MTKView?
        private var dragging = false
        private var boxStart: CGPoint?
        private var painting = false
        private var lastPinch: CGFloat = 1

        init(store: StudioStore) { self.store = store }

        private func syncSize() { if let v = view { MainActor.assumeIsolated { store.viewSize = v.bounds.size } } }

        @objc func tap(_ g: UITapGestureRecognizer) {
            syncSize()
            let p = g.location(in: view)
            MainActor.assumeIsolated {
                if let play = store.play { play.tap(x: Float(p.x), y: Float(p.y)); return }
                if store.terrainEditor.tool != nil {
                    store.terrainStroke(.began, at: p)
                    store.terrainStroke(.ended, at: p)
                    return
                }
                if store.handle(at: p) != nil { return }
                store.tap(at: p, additive: store.multiSelect)
            }
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            syncSize()
            MainActor.assumeIsolated {
                if store.play != nil { return }
                store.tap(at: g.location(in: view), additive: false)
                store.focusSelection()
            }
        }

        @objc func pan1(_ g: UIPanGestureRecognizer) {
            syncSize()
            let p = g.location(in: view)
            MainActor.assumeIsolated {
                if let play = store.play {
                    let t = g.translation(in: view)
                    play.cameraDrag(dx: Float(t.x), dy: Float(t.y))
                    g.setTranslation(.zero, in: view)
                    return
                }
                switch g.state {
                case .began:
                    // Start where the finger first touched, not where the pan was recognised.
                    let start = CGPoint(x: p.x - g.translation(in: view).x, y: p.y - g.translation(in: view).y)
                    boxStart = nil
                    painting = false
                    if store.terrainEditor.tool != nil {
                        painting = true
                        dragging = false
                        store.terrainStroke(.began, at: start)
                        store.terrainStroke(.moved, at: p)
                    } else if let h = store.handle(at: start) {
                        dragging = true
                        store.beginDrag(h, at: start)
                        store.updateDrag(at: p)
                    } else if store.boxSelect {
                        dragging = false
                        boxStart = start
                        BoxSelectState.shared.rect = CGRect(origin: start, size: .zero)
                    } else {
                        dragging = false
                    }
                case .changed:
                    if painting {
                        store.terrainStroke(.moved, at: p)
                    } else if let b = boxStart {
                        BoxSelectState.shared.rect = CGRect(x: min(b.x, p.x), y: min(b.y, p.y), width: abs(p.x - b.x), height: abs(p.y - b.y))
                    } else if dragging {
                        store.updateDrag(at: p)
                    } else {
                        let t = g.translation(in: view)
                        store.camera.rotate(-Float(t.x) * 0.006, -Float(t.y) * 0.006)
                        g.setTranslation(.zero, in: view)
                    }
                default:
                    if painting { store.terrainStroke(.ended, at: p); painting = false }
                    if boxStart != nil, let r = BoxSelectState.shared.rect {
                        store.selectInBox(r, additive: store.multiSelect)
                    }
                    boxStart = nil
                    BoxSelectState.shared.rect = nil
                    if dragging { store.endDrag(); dragging = false }
                }
            }
        }

        @objc func pan2(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            MainActor.assumeIsolated {
                if let play = store.play { play.cameraDrag(dx: Float(t.x), dy: Float(t.y)); return }
                let cam = store.camera
                let speed = max(0.05, cam.pos.y.magnitude * 0.004 + 0.05)
                cam.pos += cam.right * (-Float(t.x) * speed) + cam.up * (Float(t.y) * speed)
            }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { lastPinch = 1 }
            let d = g.scale - lastPinch
            lastPinch = g.scale
            MainActor.assumeIsolated {
                if let play = store.play { play.cameraZoom(Float(1 + d)); return }
                let cam = store.camera
                cam.pos += cam.forward * (Float(d) * 60)
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer && o is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && o is UIPinchGestureRecognizer)
        }
    }
}

/// Rectangle being dragged in box-select mode.
final class BoxSelectState: ObservableObject {
    static let shared = BoxSelectState()
    @Published var rect: CGRect?
}

struct BoxSelectOverlay: View {
    @ObservedObject var state = BoxSelectState.shared
    var body: some View {
        if let r = state.rect {
            Rectangle()
                .fill(Th.accent.opacity(0.18))
                .overlay(Rectangle().stroke(Th.info, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }
}

/// On-screen editor controls (ViewportView.TouchLayer): fly stick, up/down, fly speed and the
/// Box / Multi / In Groups selection toggles.
struct EditControls: View {
    @ObservedObject var store: StudioStore

    var body: some View {
        ZStack {
            VStack {
                Spacer()
                HStack {
                    Thumbstick { v in
                        store.flyInput.x = Float(v.x)
                        store.flyInput.z = Float(-v.y)
                    }
                    .frame(width: 124, height: 124)
                    .padding(.leading, 28).padding(.bottom, 24)
                    Spacer()
                }
            }
            VStack {
                Spacer()
                HStack(alignment: .bottom, spacing: 12) {
                    Spacer()
                    VStack(spacing: 12) {
                        Spacer().frame(height: 56)
                        roundButton("rectangle.dashed.badge.record", on: store.boxSelect, size: 56) { store.toggleBoxSelect() }
                        Spacer().frame(height: 56)
                    }
                    VStack(spacing: 12) {
                        roundButton("square.on.square", on: store.selectInsideModels, size: 56) { store.toggleInsideModels() }
                        roundButton("rectangle.dashed", on: store.multiSelect, size: 56) { store.toggleMultiSelect() }
                        Button { store.flyMul = FlySpeeds.next(store.flyMul) } label: {
                            Text(FlySpeeds.label(store.flyMul)).font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white).frame(width: 56, height: 56)
                                .background(Circle().fill(Color(white: 0.16, opacity: 0.85)))
                                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                    VStack(spacing: 12) {
                        Spacer().frame(height: 40)
                        hold("chevron.up", 1)
                        hold("chevron.down", -1)
                    }
                }
                .padding(.trailing, 22).padding(.bottom, 26)
            }
        }
    }

    private func roundButton(_ icon: String, on: Bool, size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(on ? Th.accent : Color(white: 0.16, opacity: 0.85)))
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func hold(_ icon: String, _ dir: Float) -> some View {
        Image(systemName: icon).font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 70, height: 70)
            .background(Circle().fill(Color(white: 0.16, opacity: 0.85)))
            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2.5))
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, pressing: { down in
                store.flyInput.y = down ? dir : 0
            }, perform: {})
    }
}
