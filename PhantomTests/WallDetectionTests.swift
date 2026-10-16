import XCTest
import simd
@testable import Phantom

final class WallDetectionTests: XCTestCase {
    func testPlaneEdge() {
        let none = -Float.infinity
        // Next room behind the wall, a gap in the readings, then the jamb on the wall.
        XCTAssertEqual(DepthEdge.planeEdge([-1.2, -1.1, none, 0.01, 0.02, 0.0]), 3)
        // An open door leaf meets the wall at its hinge: the edge is there,
        // not further out where the leaf swings toward the camera.
        XCTAssertEqual(DepthEdge.planeEdge([-1.5, -1.5, 0.02, 0.15, 0.4, 0.7]), 2)
        // Something in front first, then back on the wall.
        XCTAssertEqual(DepthEdge.planeEdge([-1, -1, 0.5, 0.4, 0.3, 0.03, 0.05]), 5)
        // Only something in front: use where it starts.
        XCTAssertEqual(DepthEdge.planeEdge([-1, 0.5, 0.5, 0.5]), 1)
        XCTAssertNil(DepthEdge.planeEdge([-1, -1, -1]))
    }

    /// A vertical plane anchor at z = `z` facing +z, spanning x −2…2 and y 0…2.5.
    private func wall(z: Float, penalty: Float = 0) -> WallCandidate {
        // Local y is the plane normal (+z); local z is world −y.
        let transform = simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, -1, 0, 0), SIMD4<Float>(0, 0, z, 1)))
        return WallCandidate(plane: WallPlane(point: SIMD3(0, 0, z), normal: SIMD3(0, 0, 1)),
                             penalty: penalty, transform: transform,
                             minimum: SIMD2(-2, -2.5), maximum: SIMD2(2, 0))
    }

    func testChoosesTheWallInFrontOfTheOpening() {
        let origin = SIMD3<Float>(0, 1.4, 3)
        let direction = normalize(SIMD3<Float>(0, -0.2, -3))
        let door = wall(z: 0.02, penalty: 1)
        let chosen = WallCandidate.choose([door, wall(z: 0)], origin: origin, direction: direction, before: 6)
        XCTAssertEqual(chosen?.point.z ?? 1, 0, accuracy: 1e-5)
        // Through an open doorway the far wall is seen too; the near wall has the opening.
        let near = WallCandidate.choose([wall(z: -1.5), wall(z: 0)], origin: origin, direction: direction, before: 4.6)
        XCTAssertEqual(near?.point.z ?? 1, 0, accuracy: 1e-5)
        // A plane behind what the camera sees there isn't the wall around it.
        XCTAssertNil(WallCandidate.choose([wall(z: -2)], origin: origin, direction: direction, before: 2))
        // Seen edge-on or from behind: ignored.
        XCTAssertNil(WallCandidate.choose([wall(z: 0)], origin: origin, direction: SIMD3(1, 0, 0), before: 6))
    }

    func testWallPlaneOpening() throws {
        let plane = WallPlane(point: SIMD3(5, 0, 0), normal: SIMD3(0, 0, 1))
        let opening = try XCTUnwrap(plane.opening(left: -0.4, right: 0.45, top: 2.0, bottom: 0))
        XCTAssertEqual(opening.width, 0.85, accuracy: 1e-5)
        XCTAssertEqual(opening.height, 2.0, accuracy: 1e-5)
        XCTAssertEqual(opening.center.x, 0.025, accuracy: 1e-5)
        XCTAssertEqual(opening.center.y, 1.0, accuracy: 1e-5)
        XCTAssertEqual(opening.center.z, 0, accuracy: 1e-5)
        XCTAssertNil(plane.opening(left: 0, right: 0.1, top: 2, bottom: 0))
    }

    /// Triangles covering a rectangle in the plane z = `z`, in 5 cm squares.
    private func faces(x: ClosedRange<Float>, y: ClosedRange<Float>, z: Float,
                       window: Bool = false) -> [DepthOpeningDetector.ClassifiedFace] {
        var result: [DepthOpeningDetector.ClassifiedFace] = []
        let step: Float = 0.05
        var px = x.lowerBound
        while px < x.upperBound - 1e-4 {
            var py = y.lowerBound
            while py < y.upperBound - 1e-4 {
                let a = SIMD3<Float>(px, py, z), b = SIMD3<Float>(px + step, py, z)
                let c = SIMD3<Float>(px + step, py + step, z), d = SIMD3<Float>(px, py + step, z)
                result.append(.init(a: a, b: b, c: c, isWindow: window))
                result.append(.init(a: a, b: c, c: d, isWindow: window))
                py += step
            }
            px += step
        }
        return result
    }

    func testClosedDoorFromLabels() throws {
        // A closed door 80 × 200 cm set 3 cm into the wall, a second door
        // further along the wall, and the camera aiming at the first.
        let all = faces(x: -0.4...0.4, y: 0...2.0, z: -0.03) + faces(x: 1.6...2.4, y: 0...2.0, z: -0.03)
        let origin = SIMD3<Float>(0.2, 1.4, 2.5)
        let direction = normalize(SIMD3<Float>(0, 1.1, -0.03) - origin)
        let wall = WallPlane(point: .zero, normal: SIMD3(0, 0, 1))
        let opening = try XCTUnwrap(DepthOpeningDetector.classifiedOpening(
            all, origin: origin, direction: direction, wall: wall, floorY: 0))
        XCTAssertEqual(opening.width, 0.8, accuracy: 0.04)
        XCTAssertEqual(opening.height, 2.0, accuracy: 0.04)
        XCTAssertEqual(opening.center.x, 0, accuracy: 0.03)
        XCTAssertEqual(opening.center.z, 0, accuracy: 1e-4)

        // A stray label above the door doesn't stretch it.
        let stray = faces(x: -0.1...0.1, y: 2.4...2.5, z: -0.03)
        let tidy = try XCTUnwrap(DepthOpeningDetector.classifiedOpening(
            all + stray, origin: origin, direction: direction, wall: wall, floorY: 0))
        XCTAssertEqual(tidy.height, 2.0, accuracy: 0.04)

        // Without a known wall, the door's own surface is used.
        let alone = try XCTUnwrap(DepthOpeningDetector.classifiedOpening(
            all, origin: origin, direction: direction, wall: nil, floorY: 0))
        XCTAssertEqual(alone.width, 0.8, accuracy: 0.04)
        XCTAssertEqual(alone.center.z, -0.03, accuracy: 0.01)
        XCTAssertGreaterThan(alone.normal.z, 0.99)
    }

    func testOpenDoorLeafIsNotTheOpening() {
        // Only a door leaf swung open, edge-on to the wall: not a closed door.
        var leaf: [DepthOpeningDetector.ClassifiedFace] = []
        for f in faces(x: 0...0.8, y: 0...2.0, z: 0) {
            func swing(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(-0.4, p.y, p.x) }
            leaf.append(.init(a: swing(f.a), b: swing(f.b), c: swing(f.c), isWindow: false))
        }
        let origin = SIMD3<Float>(0.3, 1.4, 2.5)
        let direction = normalize(SIMD3<Float>(-0.35, 1.2, 0.4) - origin)
        let wall = WallPlane(point: .zero, normal: SIMD3(0, 0, 1))
        XCTAssertNil(DepthOpeningDetector.classifiedOpening(leaf, origin: origin, direction: direction,
                                                            wall: wall, floorY: 0))
    }
}
