import XCTest
import simd
@testable import Phantom

final class OpeningGeometryTests: XCTestCase {
    private let camera = SIMD3<Float>(0, 1, 2)

    func testVerticalWallMeasurement() throws {
        let opening = try XCTUnwrap(Opening.make(
            cornerA: SIMD3(-0.45, 0, 0),
            cornerB: SIMD3(0.45, 2.0, 0),
            surfaceNormal: SIMD3(0, 0, 1),
            cameraPosition: camera
        ))
        XCTAssertEqual(opening.width, 0.9, accuracy: 1e-4)
        XCTAssertEqual(opening.height, 2.0, accuracy: 1e-4)
        XCTAssertEqual(opening.center.x, 0, accuracy: 1e-4)
        XCTAssertEqual(opening.center.y, 1.0, accuracy: 1e-4)
        XCTAssertEqual(opening.right.x, 1, accuracy: 1e-4)
        XCTAssertEqual(opening.up.y, 1, accuracy: 1e-4)
    }

    func testNormalIsFlippedTowardCamera() throws {
        let opening = try XCTUnwrap(Opening.make(
            cornerA: SIMD3(-0.5, 0, 0),
            cornerB: SIMD3(0.5, 1.0, 0),
            surfaceNormal: SIMD3(0, 0, -1),
            cameraPosition: camera
        ))
        XCTAssertEqual(opening.normal.z, 1, accuracy: 1e-4)
        // Right-handed frame: x × y = z.
        let z = cross(opening.right, opening.up)
        XCTAssertEqual(dot(z, opening.normal), 1, accuracy: 1e-4)
    }

    func testCornerOrderDoesNotMatter() throws {
        let a = try XCTUnwrap(Opening.make(
            cornerA: SIMD3(-0.5, 0, 0), cornerB: SIMD3(0.5, 1, 0),
            surfaceNormal: SIMD3(0, 0, 1), cameraPosition: camera))
        let b = try XCTUnwrap(Opening.make(
            cornerA: SIMD3(0.5, 1, 0), cornerB: SIMD3(-0.5, 0, 0),
            surfaceNormal: SIMD3(0, 0, 1), cameraPosition: camera))
        XCTAssertEqual(a.width, b.width, accuracy: 1e-4)
        XCTAssertEqual(a.height, b.height, accuracy: 1e-4)
        XCTAssertEqual(a.center.y, b.center.y, accuracy: 1e-4)
    }

    func testDepthBetweenCornersIsIgnored() throws {
        let opening = try XCTUnwrap(Opening.make(
            cornerA: SIMD3(-0.5, 0, 0),
            cornerB: SIMD3(0.5, 1.0, -0.2), // second hit landed in the recess
            surfaceNormal: SIMD3(0, 0, 1),
            cameraPosition: camera
        ))
        XCTAssertEqual(opening.width, 1.0, accuracy: 1e-4)
        XCTAssertEqual(opening.center.z, 0, accuracy: 1e-4)
    }

    func testTooSmallReturnsNil() {
        XCTAssertNil(Opening.make(
            cornerA: SIMD3(0, 0, 0),
            cornerB: SIMD3(0.05, 1.0, 0),
            surfaceNormal: SIMD3(0, 0, 1),
            cameraPosition: camera
        ))
    }

    func testTransformColumns() throws {
        let opening = try XCTUnwrap(Opening.make(
            cornerA: SIMD3(1, 0, 3), cornerB: SIMD3(2, 2, 3),
            surfaceNormal: SIMD3(0, 0, 1), cameraPosition: SIMD3(1.5, 1, 5)))
        XCTAssertEqual(opening.transform.translation, opening.center)
    }
}
