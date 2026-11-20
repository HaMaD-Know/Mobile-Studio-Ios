import Foundation
import simd
import StudioCore

extension Vector3 {
    var simd: SIMD3<Float> { SIMD3(x, y, z) }
    init(_ s: SIMD3<Float>) { self.init(s.x, s.y, s.z) }
}

extension CFrame {
    /// Column-major 4x4 matrix, optionally scaled per local axis.
    func matrix(scale s: Vector3 = .one) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(r00 * s.x, r10 * s.x, r20 * s.x, 0),
            SIMD4(r01 * s.y, r11 * s.y, r21 * s.y, 0),
            SIMD4(r02 * s.z, r12 * s.z, r22 * s.z, 0),
            SIMD4(x, y, z, 1)))
    }
}

extension simd_float4x4 {
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tan(fovY * 0.5), xs = ys / aspect, zs = far / (near - far)
        return simd_float4x4(columns: (SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs * near, 0)))
    }
}

/// Free-flying editor camera (port of render/FlyCamera.kt).
final class FlyCamera {
    var pos = Vector3(0, 20, 40)
    var yaw: Float = 0
    var pitch: Float = -0.4
    var fov: Float = 70

    var forward: Vector3 { Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch)) }
    var right: Vector3 { Vector3(cos(yaw), 0, -sin(yaw)) }
    var up: Vector3 { right.cross(forward).unit }

    func cframe() -> CFrame { .lookAt(pos, pos + forward) }

    func lookAt(_ target: Vector3) {
        let d = (target - pos).unit
        pitch = asin(min(1, max(-1, d.y)))
        yaw = atan2(-d.x, -d.z)
    }
    func setFrom(_ cf: CFrame) { pos = cf.position; lookAt(cf.position + cf.lookVector) }
    func rotate(_ dYaw: Float, _ dPitch: Float) {
        yaw += dYaw
        pitch = min(1.55, max(-1.55, pitch + dPitch))
    }
    func focus(on center: Vector3, radius: Float) {
        let dist = max(2.2 * radius, 6)
        pos = center - forward * dist
    }

    func viewMatrix() -> simd_float4x4 { cframe().inverse.matrix() }
    func projection(aspect: Float) -> simd_float4x4 {
        .perspective(fovY: fov * .pi / 180, aspect: aspect, near: 0.1, far: 20000)
    }

    /// World-space ray through a point in view coordinates (0...w, 0...h, origin top-left).
    func ray(x: Float, y: Float, width: Float, height: Float) -> (origin: Vector3, dir: Vector3) {
        let ndcX = x / width * 2 - 1, ndcY = 1 - y / height * 2
        let t = tan(fov * .pi / 360)
        let aspect = width / max(height, 1)
        let d = (forward + right * (ndcX * t * aspect) + up * (ndcY * t)).unit
        return (pos, d)
    }

    /// Project a world point to view coordinates; nil if behind the camera.
    func project(_ p: Vector3, width: Float, height: Float) -> SIMD2<Float>? {
        let local = cframe().pointToObject(p)
        guard local.z < -0.05 else { return nil }
        let t = tan(fov * .pi / 360), aspect = width / max(height, 1)
        let nx = local.x / (-local.z * t * aspect), ny = local.y / (-local.z * t)
        return SIMD2((nx + 1) / 2 * width, (1 - ny) / 2 * height)
    }
}
