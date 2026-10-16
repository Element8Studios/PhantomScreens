import XCTest
import simd
@testable import Phantom

final class CameraModelTests: XCTestCase {
    /// A camera at (0, 1.5, 3) looking down −z with a 1920×1440 image shown
    /// on a 390×844 portrait view (rotated, as ARKit's display transform does).
    private func makeCamera() -> CameraModel {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(0, 1.5, 3, 1)
        let intrinsics = simd_float3x3(columns: (SIMD3(1500, 0, 0), SIMD3(0, 1500, 0), SIMD3(960, 720, 1)))
        // Portrait display of a landscape sensor image: view (x, y) = (1 - v, u).
        let toView = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        return CameraModel(transform: transform, intrinsics: intrinsics,
                           imageSize: CGSize(width: 1920, height: 1440),
                           toView: toView, viewSize: CGSize(width: 390, height: 844))
    }

    func testProjectUnprojectRoundTrip() throws {
        let camera = makeCamera()
        let point = CGPoint(x: 120, y: 300)
        let world = camera.unproject(point, depth: 2.5)
        let back = try XCTUnwrap(camera.project(world))
        XCTAssertEqual(back.x, point.x, accuracy: 0.01)
        XCTAssertEqual(back.y, point.y, accuracy: 0.01)
    }

    func testDepthIsAlongTheViewAxis() {
        let camera = makeCamera()
        let world = camera.unproject(CGPoint(x: 195, y: 422), depth: 2)
        XCTAssertEqual(world.z, 1, accuracy: 0.01) // camera at z = 3, looking toward −z
    }

    func testBehindTheCameraIsNotProjected() {
        XCTAssertNil(makeCamera().project(SIMD3(0, 1.5, 5)))
    }
}
