import SwiftUI
import MetalKit
import StudioCore

/// The 3D viewport (port of ui/ViewportView.kt's edit-mode input):
/// tap = select, drag on a handle = move/scale/rotate, 1-finger drag = look around,
/// 2-finger drag = pan, pinch = fly forward/back, double-tap = focus selection.
struct ViewportView: UIViewRepresentable {
    @ObservedObject var store: StudioStore
    var multiSelect: Bool

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
        context.coordinator.multiSelect = multiSelect
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let store: StudioStore
        var renderer: SceneRenderer?
        weak var view: MTKView?
        var multiSelect = false
        private var dragging = false
        private var lastPinch: CGFloat = 1

        init(store: StudioStore) { self.store = store }

        private func syncSize() { if let v = view { MainActor.assumeIsolated { store.viewSize = v.bounds.size } } }

        @objc func tap(_ g: UITapGestureRecognizer) {
            syncSize()
            let p = g.location(in: view)
            MainActor.assumeIsolated {
                if store.handle(at: p) != nil { return }
                store.tap(at: p, additive: multiSelect)
            }
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            syncSize()
            MainActor.assumeIsolated {
                store.tap(at: g.location(in: view), additive: false)
                store.focusSelection()
            }
        }

        @objc func pan1(_ g: UIPanGestureRecognizer) {
            syncSize()
            let p = g.location(in: view)
            MainActor.assumeIsolated {
                switch g.state {
                case .began:
                    // Start where the finger first touched, not where the pan was recognised.
                    let start = CGPoint(x: p.x - g.translation(in: view).x, y: p.y - g.translation(in: view).y)
                    if let h = store.handle(at: start) {
                        dragging = true
                        store.beginDrag(h, at: start)
                        store.updateDrag(at: p)
                    } else {
                        dragging = false
                    }
                case .changed:
                    if dragging {
                        store.updateDrag(at: p)
                    } else {
                        let t = g.translation(in: view)
                        store.camera.rotate(-Float(t.x) * 0.006, -Float(t.y) * 0.006)
                        g.setTranslation(.zero, in: view)
                    }
                default:
                    if dragging { store.endDrag(); dragging = false }
                }
            }
        }

        @objc func pan2(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: view)
            g.setTranslation(.zero, in: view)
            MainActor.assumeIsolated {
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
                let cam = store.camera
                cam.pos += cam.forward * (Float(d) * 60)
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool {
            (g is UIPinchGestureRecognizer && o is UIPanGestureRecognizer) || (g is UIPanGestureRecognizer && o is UIPinchGestureRecognizer)
        }
    }
}

/// Hold-to-fly buttons (the Android app's on-screen fly controls).
struct FlyPad: View {
    @ObservedObject var store: StudioStore

    var body: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(spacing: 6) {
                hold("chevron.up", SIMD3(0, 0, 1))
                HStack(spacing: 6) {
                    hold("chevron.left", SIMD3(-1, 0, 0))
                    hold("chevron.down", SIMD3(0, 0, -1))
                    hold("chevron.right", SIMD3(1, 0, 0))
                }
            }
            VStack(spacing: 6) {
                hold("arrow.up.to.line", SIMD3(0, 1, 0))
                hold("arrow.down.to.line", SIMD3(0, -1, 0))
            }
        }
    }

    private func hold(_ symbol: String, _ dir: SIMD3<Float>) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, pressing: { down in
                if down { store.flyInput += dir } else { store.flyInput -= dir }
            }, perform: {})
    }
}
