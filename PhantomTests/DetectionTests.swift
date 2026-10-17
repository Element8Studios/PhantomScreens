import XCTest
import simd
@testable import Phantom

final class DetectionTests: XCTestCase {
    func testMedianIgnoresMissing() {
        XCTAssertEqual(DepthEdge.median([3, .infinity, 1, 2]), 2)
        XCTAssertEqual(DepthEdge.median([.infinity]), .infinity)
    }

    func testOpeningCorners() throws {
        let opening = try XCTUnwrap(Opening.make(
            cornerA: SIMD3(-0.5, 0, 0), cornerB: SIMD3(0.5, 2, 0),
            surfaceNormal: SIMD3(0, 0, 1), cameraPosition: SIMD3(0, 1, 2)))
        let c = opening.corners
        XCTAssertEqual(c[0].x, -0.5, accuracy: 1e-4); XCTAssertEqual(c[0].y, 2, accuracy: 1e-4)
        XCTAssertEqual(c[2].x, 0.5, accuracy: 1e-4); XCTAssertEqual(c[2].y, 0, accuracy: 1e-4)
    }
}
