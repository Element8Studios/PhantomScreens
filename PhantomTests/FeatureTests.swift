import XCTest
import UIKit
@testable import Phantom

final class FeatureTests: XCTestCase {
    func testNearWallSkipsThingsInsideTheOpening() {
        // Far wall 4 m; a stair wall at 3.3 m inside the opening; trim at 2 m.
        let samples: [Float] = [4, 4, 3.3, 3.3, 3.3, 2.0, 2.0, 2.0, 2.05, 2.1, 2.0, 2.0]
        XCTAssertEqual(DepthEdge.nearWall(samples, openingDepth: 4), 5)
        // No wall clearly in front: nothing found.
        XCTAssertNil(DepthEdge.nearWall([4, 4, 3.9, 3.9, 3.95, 4, 4, 3.9], openingDepth: 4))
    }

    func testFirstOnPlane() {
        let inf = -Float.infinity
        // Behind the wall (inside the opening), then back on the header.
        XCTAssertEqual(DepthEdge.firstOnPlane([-1.5, -1.4, inf, -0.02, 0.01, 0.0]), 3)
        XCTAssertNil(DepthEdge.firstOnPlane([-1, -1, -0.5]))
    }

    func testHexColourRoundTrip() {
        let color = UIColor(hex: "#E9E6DF")
        XCTAssertNotNil(color)
        XCTAssertEqual(color?.hexString, "#E9E6DF")
        XCTAssertNil(UIColor(hex: "nope"))
    }

    func testOldSavedDesignsStillDecode() throws {
        let json = #"{"product":"single","side":"left","finish":"mineralBronze","mesh":"insect","mount":"inside","width":0.9,"height":2.0,"extent":1}"#
        let config = try JSONDecoder().decode(ScreenConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.finish, .mineralBronze)
        XCTAssertFalse(config.customMatchedToTrim)
        XCTAssertNil(config.customColorNote)
    }

    func testCustomColourNote() {
        var config = ScreenConfig()
        config.finish = .custom
        config.customColorHex = "#D8D2C4"
        config.customMatchedToTrim = true
        XCTAssertTrue(config.customColorNote?.contains("#D8D2C4") ?? false)
        XCTAssertTrue(config.customColorNote?.contains("trim") ?? false)
        XCTAssertEqual(config.finishTitle, "Custom Color #D8D2C4")
    }

    func testSunAtEquinoxNoonIsOverhead() {
        // 2024-03-20 12:07 UTC is close to solar noon at 0°, 0°.
        let date = Date(timeIntervalSince1970: 1_710_936_420)
        let sun = SunPosition.compute(date: date, latitude: 0, longitude: 0)
        XCTAssertGreaterThan(sun.elevation, 85)
    }

    func testSunInNewYorkSummerNoon() {
        // 2024-06-21 17:00 UTC: near solar noon in New York, sun to the south, ~72° high.
        let date = Date(timeIntervalSince1970: 1_718_989_200)
        let sun = SunPosition.compute(date: date, latitude: 40.71, longitude: -74.0)
        XCTAssertEqual(sun.elevation, 72.7, accuracy: 2)
        XCTAssertEqual(sun.azimuth, 180, accuracy: 6)
        let direction = SunPosition.direction(azimuth: sun.azimuth, elevation: sun.elevation)
        XCTAssertGreaterThan(direction.z, 0) // south is +z in ARKit's heading-aligned world
    }

    func testSunsetIsLowInTheWest() {
        // 2024-06-21 00:20 UTC = 20:20 EDT on the 20th, close to sunset in New York.
        let date = Date(timeIntervalSince1970: 1_718_929_200)
        let sun = SunPosition.compute(date: date, latitude: 40.71, longitude: -74.0)
        XCTAssertLessThan(sun.elevation, 8)
        XCTAssertEqual(sun.azimuth, 300, accuracy: 10)
    }

    func testMeshLock() throws {
        let json = #"{"product":"single","finish":"classicWhite","mesh":"insect"}"#
        var config = try JSONDecoder().decode(ScreenConfig.self, from: Data(json.utf8))
        XCTAssertFalse(config.meshLock)
        config.meshLock = true
        XCTAssertTrue(config.hasMeshLock)
        XCTAssertTrue(config.summary.localizedCaseInsensitiveContains("mesh lock"))
        let round = try JSONDecoder().decode(ScreenConfig.self, from: JSONEncoder().encode(config))
        XCTAssertTrue(round.meshLock)
        // Windows, oversized and motorized screens don't offer it.
        for product in [Product.window, .oversized, .motorized] {
            config.product = product
            XCTAssertFalse(config.hasMeshLock)
            XCTAssertFalse(config.summary.localizedCaseInsensitiveContains("mesh lock"))
        }
    }

    func testColors() {
        XCTAssertEqual(FrameFinish.standard.count, 10)
        XCTAssertFalse(FrameFinish.standard.contains(.woodGrain))
        XCTAssertFalse(FrameFinish.standard.contains(.custom))
        XCTAssertEqual(FrameFinish.woodGrain.tag, .additional)
        XCTAssertEqual(FrameFinish.hartfordGreen.tag, .included)
        var config = ScreenConfig()
        config.finish = .woodGrain
        XCTAssertEqual(config.finishTitle, "Wood grain")
        XCTAssertNil(config.customColorNote)
        // Undecided keeps the preview color but says so in the order.
        config.colorUndecided = true
        XCTAssertTrue(config.lineItems(unit: .inches).contains { $0.label == "Color" && $0.value == "Undecided" })
        // The camera sees trim darker than the swatch; hue still finds white, green, black.
        XCTAssertEqual(FrameFinish.closest(to: UIColor(white: 0.82, alpha: 1)), .classicWhite)
        XCTAssertEqual(FrameFinish.closest(to: UIColor(red: 0.08, green: 0.2, blue: 0.13, alpha: 1)), .hartfordGreen)
    }

    func testSizeBandsFollowTheWebsite() {
        let inch = Length.metresPerInch
        XCTAssertEqual(SizeBand.band(for: 80 * inch, in: SizeBand.heights)?.tag, .included)
        XCTAssertEqual(SizeBand.band(for: 84 * inch, in: SizeBand.heights)?.tag, .included)
        XCTAssertEqual(SizeBand.band(for: 90 * inch, in: SizeBand.heights)?.upper, 96)
        XCTAssertEqual(SizeBand.band(for: 110 * inch, in: SizeBand.heights)?.upper, 120)
        XCTAssertNil(SizeBand.band(for: 130 * inch, in: SizeBand.heights))
        XCTAssertEqual(SizeBand.band(for: 35 * inch, in: SizeBand.widths)?.tag, .included)
        XCTAssertEqual(SizeBand.band(for: 40 * inch, in: SizeBand.widths)?.tag, .additional)
        XCTAssertEqual(SizeBand.heights[0].title(.inches), "84\" or less")
        XCTAssertEqual(SizeBand.heights[1].title(.inches), "84 ¼\" to 96\"")

        var config = ScreenConfig()
        config.width = 40 * inch
        config.height = 82 * inch
        XCTAssertEqual(config.widthBand?.upper, 48)
        XCTAssertEqual(config.heightBand?.upper, 84)
        XCTAssertTrue(config.fitsProduct)
        config.width = 60 * inch
        XCTAssertFalse(config.fitsProduct)
        config.product = .double
        XCTAssertTrue(config.fitsProduct)
        XCTAssertNil(config.widthBand)
    }

    func testOrderDefaultsAndNoPrices() throws {
        let config = ScreenConfig()
        XCTAssertEqual(config.closure, .latching)
        XCTAssertEqual(config.mesh, .insect)
        let items = config.lineItems(unit: .inches)
        XCTAssertTrue(items.contains { $0.label == "Closure" && $0.tag == .additional })
        XCTAssertFalse(items.contains { $0.value.contains("$") })
        // Designs saved before closures existed still load, with the default.
        let json = #"{"product":"double","finish":"coastalGrey","mesh":"sun","mount":"inside","width":1.6,"height":2.0,"extent":1}"#
        let old = try JSONDecoder().decode(ScreenConfig.self, from: Data(json.utf8))
        XCTAssertEqual(old.product, .double)
        XCTAssertEqual(old.closure, .latching)
        XCTAssertTrue(old.mesh.isCustom)
    }

    @MainActor
    func testHardwareSitsAroundTheMeshArea() {
        var config = ScreenConfig()
        config.width = 0.9
        config.height = 2.0
        config.side = .left
        config.meshLock = true
        // Surface mount: the mesh fills the measured opening, hardware outside it.
        config.mount = .outside
        for product in Product.allCases {
            config.product = product
            config.extent = 1
            let door = ScreenDoorEntity(config: config)
            XCTAssertEqual(door.tracks.count, product == .double ? 2 : 1, "\(product)")
            let vertical = product == .window || product == .motorized
            for track in door.tracks {
                let bar = vertical ? abs(track.bar.y) : abs(track.bar.x)
                let edge = vertical ? config.height / 2 : config.width / 2
                switch product {
                case .double:
                    // The two bars meet in the middle.
                    XCTAssertEqual(bar, ScreenDoorEntity.barWidth / 2, accuracy: 0.001)
                case .motorized:
                    // The bottom bar rests on the floor inside the opening.
                    XCTAssertEqual(bar, edge - ScreenDoorEntity.bottomBar / 2, accuracy: 0.001)
                case .oversized:
                    XCTAssertEqual(bar, edge + ScreenDoorEntity.DoorHardware.oversized.barWidth / 2, accuracy: 0.001)
                default:
                    // Closed, the bar is just outside the rectangle.
                    XCTAssertEqual(bar, edge + ScreenDoorEntity.barWidth / 2, accuracy: 0.001, "\(product)")
                }
            }
        }
        // Inside the jamb, everything fits within the measured opening.
        config.mount = .inside
        for product in [Product.single, .double, .window, .motorized] {
            config.product = product
            let door = ScreenDoorEntity(config: config)
            for track in door.tracks {
                XCTAssertLessThan(abs(track.bar.x), config.width / 2, "\(product)")
                XCTAssertLessThan(abs(track.bar.y), config.height / 2, "\(product)")
                XCTAssertLessThan(track.bar.z, 0, "set back behind the trim: \(product)")
            }
        }
        config.mount = .outside

        // Past 15 ft an oversized opening gets two screens.
        config.product = .oversized
        config.width = 5.5
        XCTAssertEqual(ScreenDoorEntity(config: config).tracks.count, 2)
        let hardware = ScreenDoorEntity.DoorHardware.standard
        XCTAssertNotNil(ScreenDoorEntity.chamferedMesh(length: 2.03, width: hardware.housingWidth,
                                                       depth: hardware.housingDepth, chamfer: hardware.chamfer,
                                                       vertical: true))
        XCTAssertNotNil(ScreenDoorEntity.windowHousingMesh(length: 0.93))
    }

    func testWhiteTrimUnderWarmLightStaysWhite() {
        // White trim under 3000 K light, after the camera has removed part
        // of the warm cast, reads as a tan color to the camera.
        let kelvin: Float = 3000
        let cast = ColorTemperature.rgb(kelvin: kelvin) / ColorTemperature.rgb(kelvin: 6500)
        let residual = SIMD3<Float>(pow(cast.x, 0.4), pow(cast.y, 0.4), pow(cast.z, 0.4))
        func seen(_ finish: FrameFinish) -> UIColor {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            finish.uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            let c = SIMD3<Float>(Float(r), Float(g), Float(b)) * residual * 0.9
            return UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        }
        XCTAssertNotEqual(FrameFinish.closest(to: seen(.classicWhite)), .classicWhite,
                          "without the light's color, warm white looks tan")
        XCTAssertEqual(FrameFinish.closest(to: seen(.classicWhite), lightKelvin: kelvin), .classicWhite)
        // A genuinely tan finish stays tan.
        XCTAssertEqual(FrameFinish.closest(to: seen(.sandalWood), lightKelvin: kelvin), .sandalWood)
    }

    @MainActor
    func testChangingOptionsKeepsTheScreenWhereItIs() {
        var config = ScreenConfig()
        config.extent = 0
        let door = ScreenDoorEntity(config: config)
        XCTAssertEqual(door.extent, 0, accuracy: 1e-6)
        door.setExtent(0.6)
        // Color, mesh, closure and even product changes don't move it.
        config.finish = .phantomBlack
        door.update(config)
        config.mesh = .pet
        config.closure = .magnet
        door.update(config)
        config.product = .double
        door.update(config)
        XCTAssertEqual(door.extent, 0.6, accuracy: 1e-6)
    }

    func testOrderLinesLinkToTheirOptions() {
        let items = ScreenConfig().lineItems(unit: .inches)
        XCTAssertEqual(items.first { $0.label == "Color" }?.step, .color)
        XCTAssertEqual(items.first { $0.label == "Closure" }?.step, .closure)
        XCTAssertEqual(items.first { $0.label == "Height" }?.step, .measurement)
        XCTAssertEqual(OptionStep.steps(for: .window), [.color, .mesh, .measurement, .type])
        XCTAssertEqual(OptionStep.steps(for: .motorized), [.color, .mesh, .control, .measurement, .type])
        var motorized = ScreenConfig()
        motorized.product = .motorized
        motorized.guide = .cables
        let lines = motorized.lineItems(unit: .inches)
        XCTAssertEqual(lines.first { $0.label == "Motor" }?.step, .control)
        XCTAssertEqual(lines.first { $0.label == "Guides" }?.value, "Cable guides")
        XCTAssertNil(lines.first { $0.label == "Headbox" })
    }

    func testMotorizedOptions() {
        XCTAssertEqual(MeshType.customOptions, [.pet, .sun, .privacy])
        XCTAssertEqual(MeshType.vinylOptions, [.clearVinyl, .vinylMesh])
        XCTAssertFalse(MotorType.solar.isAvailable)
        let config = ScreenConfig()
        XCTAssertEqual(config.motor, .electric)
        XCTAssertEqual(config.guide, .tracks)
        XCTAssertFalse(config.recessedHeadbox)
    }

    func testMotorizedVinylIsAType() {
        var config = ScreenConfig()
        config.product = .motorized
        XCTAssertFalse(config.isVinyl)
        XCTAssertEqual(OptionStep.mesh.tabTitle(for: config), "Mesh")
        config.mesh = .clearVinyl
        XCTAssertTrue(config.isVinyl)
        XCTAssertFalse(config.showsMesh)
        XCTAssertEqual(config.typeTitle, "Motorized Vinyl Screen")
        XCTAssertEqual(OptionStep.mesh.tabTitle(for: config), "Vinyl")
        let lines = config.lineItems(unit: .inches)
        XCTAssertEqual(lines.first { $0.label == "Vinyl" }?.step, .mesh)
        XCTAssertEqual(lines.first { $0.label == "Vinyl color" }?.step, .color)
        XCTAssertNil(lines.first { $0.label == "Mesh color" })
        config.mesh = .vinylMesh
        XCTAssertTrue(config.lineItems(unit: .inches).contains { $0.label == "Mesh color" })
        // Every product has a mesh color.
        XCTAssertEqual(ScreenConfig().lineItems(unit: .inches).first { $0.label == "Mesh color" }?.value, "Black")
    }

    @MainActor
    func testVinylCablesAndRecessedHeadboxBuild() {
        var config = ScreenConfig()
        config.product = .motorized
        config.mesh = .vinylMesh
        config.guide = .cables
        config.recessedHeadbox = true
        let door = ScreenDoorEntity(config: config)
        door.setExtent(0.5)
        door.setExtent(1)
        config.vinylColor = .white
        config.meshColor = .grey
        door.update(config)
        door.setExtent(0.3)
        XCTAssertEqual(ScreenDoorEntity.reach(for: config).top, ScreenDoorEntity.recessedSlot, accuracy: 1e-6)
        XCTAssertEqual(ScreenDoorEntity.reach(for: config).left, ScreenDoorEntity.cableGuide, accuracy: 1e-6)
        XCTAssertFalse(door.paintSamplePoints.isEmpty)
    }

    @MainActor
    func testBugsGetInOnlyWhereTheScreenIsOpen() {
        var config = ScreenConfig()
        config.product = .single
        let door = ScreenDoorEntity(config: config)
        door.setExtent(1)
        XCTAssertTrue(door.isCovered(x: 0, y: 0))
        door.setExtent(0)
        XCTAssertFalse(door.isCovered(x: 0, y: 0))

        config.product = .motorized
        let motorized = ScreenDoorEntity(config: config)
        motorized.setExtent(0.5)
        // Lowered halfway: the top half is screened, the bottom half open.
        XCTAssertTrue(motorized.isCovered(x: 0, y: config.height * 0.25))
        XCTAssertFalse(motorized.isCovered(x: 0, y: -config.height * 0.25))
    }

    @MainActor
    func testTrimSeenAgainstTheRoomsWhite() {
        func linear(_ srgb: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(pow(srgb.x, 2.2), pow(srgb.y, 2.2), pow(srgb.z, 2.2))
        }
        let warm = SIMD3<Float>(1, 0.78, 0.5)     // warm bulbs
        let white = linear(SIMD3(0.95, 0.945, 0.925))
        let almond = linear(SIMD3(0.90, 0.85, 0.77))
        let room = white * warm * 0.8
        func suggested(_ paint: SIMD3<Float>, shade: Float) -> FrameFinish {
            let seen = PhantomSession.relative(paint * warm * 0.8 * shade, to: room)
            return FrameFinish.closest(to: PhantomSession.srgbColor(seen))
        }
        XCTAssertEqual(suggested(white, shade: 1), .classicWhite)
        XCTAssertEqual(suggested(white, shade: 0.5), .classicWhite, "white trim in shadow stays white")
        XCTAssertEqual(suggested(almond, shade: 1), .sliveredAlmond)
        XCTAssertEqual(suggested(linear(SIMD3(0.45, 0.45, 0.45)), shade: 1), .coastalGrey)
    }
}
