import XCTest
import simd
@testable import Phantom

final class FitTests: XCTestCase {
    private let camera = SIMD3<Float>(0, 1, 3)

    private func corners(width: Float, height: Float, z: [Float] = [0, 0, 0, 0]) -> [SIMD3<Float>] {
        [SIMD3(-width / 2, height, z[0]), SIMD3(width / 2, height, z[1]),
         SIMD3(width / 2, 0, z[2]), SIMD3(-width / 2, 0, z[3])]
    }

    func testFlatRectangle() throws {
        let o = try XCTUnwrap(Opening.fit(corners: corners(width: 0.9, height: 2), plumb: true, cameraPosition: camera))
        XCTAssertEqual(o.width, 0.9, accuracy: 1e-4)
        XCTAssertEqual(o.height, 2, accuracy: 1e-4)
        XCTAssertEqual(o.normal.z, 1, accuracy: 1e-4)
        XCTAssertEqual(o.center.y, 1, accuracy: 1e-4)
        XCTAssertEqual(dot(cross(o.right, o.up), o.normal), 1, accuracy: 1e-4)
    }

    func testTurnedWallIsFollowed() throws {
        // Right side 20 cm further from the camera: the wall is turned.
        let o = try XCTUnwrap(Opening.fit(corners: corners(width: 1, height: 2, z: [0, -0.2, -0.2, 0]),
                                          plumb: true, cameraPosition: camera))
        XCTAssertGreaterThan(o.normal.x, 0.1)
        XCTAssertEqual(o.normal.y, 0, accuracy: 1e-5)
        XCTAssertEqual(o.width, sqrt(1 + 0.04), accuracy: 1e-3)
    }

    func testPlumbIgnoresLean() throws {
        // Top leans 10 cm toward the camera.
        let leaning = corners(width: 1, height: 2, z: [0.1, 0.1, 0, 0])
        let plumb = try XCTUnwrap(Opening.fit(corners: leaning, plumb: true, cameraPosition: camera))
        XCTAssertEqual(plumb.up.y, 1, accuracy: 1e-5)
        let free = try XCTUnwrap(Opening.fit(corners: leaning, plumb: false, cameraPosition: camera))
        XCTAssertLessThan(free.up.y, 0.999)
        XCTAssertGreaterThan(free.up.z, 0)
    }

    func testCornerOrderMirrored() {
        // Corners given right-to-left still produce a valid opening.
        let c = corners(width: 1, height: 2)
        XCTAssertNotNil(Opening.fit(corners: [c[1], c[0], c[3], c[2]], plumb: true, cameraPosition: camera))
    }
}
