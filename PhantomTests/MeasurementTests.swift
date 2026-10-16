import CoreGraphics
import XCTest
@testable import Phantom

final class MeasurementTests: XCTestCase {
    func testEighthInchFormatting() {
        XCTAssertEqual(Length.string(35.875 * 0.0254, unit: .inches), "35 ⅞ in")
        XCTAssertEqual(Length.string(79.5 * 0.0254, unit: .inches), "79 ½ in")
        XCTAssertEqual(Length.string(36 * 0.0254, unit: .inches), "36 in")
        XCTAssertEqual(Length.string(1.0, unit: .inches), "39 ⅜ in")
    }

    func testCentimetreFormatting() {
        XCTAssertEqual(Length.string(1.0, unit: .centimeters), "100.0 cm")
    }

    func testSizeString() {
        XCTAssertEqual(Length.size(width: 36 * 0.0254, height: 80 * 0.0254, unit: .inches), "36 × 80 in")
    }

    func testProductSuggestion() {
        XCTAssertEqual(Product.suggested(width: 0.9, height: 2.03), .single)
        XCTAssertEqual(Product.suggested(width: 1.8, height: 2.03), .double)
        XCTAssertEqual(Product.suggested(width: 0.9, height: 1.2), .window)
        // A tall window starts well above the floor.
        XCTAssertEqual(Product.suggested(width: 1.0, height: 1.9, sill: 0.6), .window)
        XCTAssertEqual(Product.suggested(width: 3.5, height: 2.4), .oversized)
        XCTAssertEqual(Product.suggested(width: 6.0, height: 2.8), .motorized)
        XCTAssertEqual(Product.suggested(width: 3.5, height: 2.4, outdoors: true), .motorized)
    }

    @MainActor
    func testQuadOrdering() {
        let points = [CGPoint(x: 280, y: 560), CGPoint(x: 110, y: 170), CGPoint(x: 112, y: 562), CGPoint(x: 281, y: 168)]
        let ordered = DepthOpeningDetector.ordered(points)
        XCTAssertEqual(ordered[0], CGPoint(x: 110, y: 170))
        XCTAssertEqual(ordered[1], CGPoint(x: 281, y: 168))
        XCTAssertEqual(ordered[2], CGPoint(x: 280, y: 560))
        XCTAssertEqual(ordered[3], CGPoint(x: 112, y: 562))
    }
}
