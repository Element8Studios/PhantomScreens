import SwiftUI
import UIKit

// The Phantom Screens product catalog, matching the options on
// phantomscreens.com. Prices vary by region, so options only say whether
// they're included or cost extra; the local expert quotes the rest.

// MARK: - Products

/// What's being screened.
enum OpeningCategory: String, CaseIterable, Identifiable, Codable {
    case door, window, outdoor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .door: return "Door"
        case .window: return "Window"
        case .outdoor: return "Outdoor space"
        }
    }

    var symbol: String {
        switch self {
        case .door: return "door.left.hand.open"
        case .window: return "window.vertical.open"
        case .outdoor: return "sun.max"
        }
    }

    var products: [Product] { Product.allCases.filter { $0.category == self } }
}

enum Product: String, CaseIterable, Identifiable, Codable {
    // "single", "double" and "window" keep their raw values so designs saved
    // by earlier versions still load.
    case single, sliding, double, oversized, window, motorized

    var id: String { rawValue }

    var category: OpeningCategory {
        switch self {
        case .single, .sliding, .double, .oversized: return .door
        case .window: return .window
        case .motorized: return .outdoor
        }
    }

    var title: String {
        switch self {
        case .single: return "Single Door Screen"
        case .sliding: return "Sliding Door Screen"
        case .double: return "Double-French Door Screens"
        case .oversized: return "Oversized Door Screen"
        case .window: return "Window Screen"
        case .motorized: return "Motorized Screen"
        }
    }

    var shortTitle: String {
        switch self {
        case .single: return "Single"
        case .sliding: return "Sliding"
        case .double: return "Double-French"
        case .oversized: return "Oversized"
        case .window: return "Window"
        case .motorized: return "Motorized"
        }
    }

    var detail: String {
        switch self {
        case .single: return "For a single hinged door."
        case .sliding: return "For a sliding patio door."
        case .double: return "Two screens that meet in the middle, for French doors."
        case .oversized: return "For folding, multi-panel and lift-and-slide doors, up to 15 ft wide with one screen."
        case .window: return "Pulls down over the window and rolls away when you don't need it."
        case .motorized: return "For porches, patios and pergolas. Lowers and raises at the touch of a button."
        }
    }

    var symbol: String {
        switch self {
        case .single: return "door.left.hand.open"
        case .sliding: return "door.sliding.left.hand.open"
        case .double: return "door.french.open"
        case .oversized: return "square.split.2x1"
        case .window: return "window.vertical.open"
        case .motorized: return "sun.max"
        }
    }

    /// Housing on one side, so the side it retracts into matters.
    var hasRetractSide: Bool { self == .single || self == .sliding || self == .oversized }
    var offersMeshLock: Bool { self == .single || self == .sliding || self == .double }
    var offersClosure: Bool { category == .door }
    /// The website's height and width bands apply to these.
    var usesSizeBands: Bool { self == .single || self == .sliding }
    var isMotorized: Bool { self == .motorized }

    /// Largest opening this product covers, in metres, from Phantom's
    /// published limits. Larger openings need a custom quote.
    var maxSize: SIMD2<Float> {
        let foot: Float = 0.3048
        switch self {
        case .single, .sliding: return SIMD2(48 * Length.metresPerInch, 120 * Length.metresPerInch)
        case .double: return SIMD2(96 * Length.metresPerInch, 120 * Length.metresPerInch)
        case .oversized: return SIMD2(30 * foot, 12 * foot)   // two screens; 15 ft with one
        case .window: return SIMD2(10 * foot, 10 * foot)
        case .motorized: return SIMD2(40 * foot, 16 * foot)
        }
    }

    func fits(width: Float, height: Float) -> Bool {
        width <= maxSize.x + 0.005 && height <= maxSize.y + 0.005
    }

    /// Best guess from a measured opening.
    /// - Parameters:
    ///   - sill: height of the opening's bottom edge above the floor, if known.
    ///   - outdoors: the light suggests the phone is outside.
    static func suggested(width: Float, height: Float, sill: Float? = nil, outdoors: Bool = false) -> Product {
        if let sill, sill > 0.3, height < 2.4 { return .window }
        if height < 1.75 { return .window }
        if width > 4.6 || height > 3.7 { return .motorized }
        if outdoors, width > 2.4 { return .motorized }
        if width > 2.45 { return .oversized }
        if width > 1.25 { return .double }
        return .single
    }
}

// MARK: - Options

/// Whether an option is part of the base product. Amounts vary by region.
enum PriceTag: Equatable {
    case included, additional

    var label: String { self == .included ? "Included" : "Additional cost" }
}

enum Closure: String, CaseIterable, Identifiable, Codable {
    case latching, latchingWithStop, magnet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latching: return "Latching Handle"
        case .latchingWithStop: return "Latching Handle with Latch Stop"
        case .magnet: return "Magnet Handle"
        }
    }

    var shortTitle: String {
        switch self {
        case .latching: return "Latching handle"
        case .latchingWithStop: return "Latch stop"
        case .magnet: return "Magnet handle"
        }
    }

    var note: String? { self == .latching ? "Chosen by 90% of our customers" : nil }
    var tag: PriceTag { self == .magnet ? .included : .additional }
}

enum MotorControl: String, CaseIterable, Identifiable, Codable {
    case remote, wallSwitch, smartHome

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remote: return "Remote control"
        case .wallSwitch: return "Wall switch"
        case .smartHome: return "Smart home"
        }
    }

    var detail: String {
        switch self {
        case .remote: return "A handheld remote raises and lowers the screen."
        case .wallSwitch: return "A switch mounted by the opening."
        case .smartHome: return "Works with your home automation. Your expert confirms compatibility."
        }
    }
}

enum MeshType: String, CaseIterable, Identifiable, Codable {
    case insect, pet, sun, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insect: return "Insect mesh"
        case .pet: return "Pet mesh"
        case .sun: return "Sun & heat mesh"
        case .privacy: return "Privacy mesh"
        }
    }

    var shortTitle: String {
        switch self {
        case .insect: return "Insect"
        case .pet: return "Pet"
        case .sun: return "Sun & heat"
        case .privacy: return "Privacy"
        }
    }

    var detail: String {
        switch self {
        case .insect: return "Clear views with everyday insect protection."
        case .pet: return "Tougher mesh that stands up to paws and claws."
        case .sun: return "Cuts glare and heat on sunny openings."
        case .privacy: return "Daytime privacy while air still flows through."
        }
    }

    /// Everything but insect mesh is a custom mesh.
    var isCustom: Bool { self != .insect }
    var tag: PriceTag { isCustom ? .additional : .included }
    static var customOptions: [MeshType] { allCases.filter(\.isCustom) }
}

enum RetractSide: String, CaseIterable, Identifiable, Codable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? "Left" : "Right" }
}

enum Mount: String, CaseIterable, Identifiable, Codable {
    case inside, outside
    var id: String { rawValue }
    var title: String { self == .inside ? "Inside" : "Outside" }
}

enum FrameFinish: String, CaseIterable, Identifiable, Codable {
    case classicWhite, calicoLinen, sliveredAlmond, sandalWood, driftwoodBeige
    case hartfordGreen, rideauBrown, coastalGrey, mineralBronze, phantomBlack
    case woodGrain, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classicWhite: return "Classic White"
        case .calicoLinen: return "Calico Linen"
        case .sliveredAlmond: return "Slivered Almond"
        case .sandalWood: return "Sandal Wood"
        case .driftwoodBeige: return "Driftwood Beige"
        case .hartfordGreen: return "Hartford Green"
        case .rideauBrown: return "Rideau Brown"
        case .coastalGrey: return "Coastal Grey"
        case .mineralBronze: return "Mineral Bronze"
        case .phantomBlack: return "Phantom Black"
        case .woodGrain: return "Wood grain"
        case .custom: return "Custom Color"
        }
    }

    /// The ten standard powder-coat colors, in the website's order.
    static var standard: [FrameFinish] { allCases.filter { $0 != .woodGrain && $0 != .custom } }
    var tag: PriceTag { (self == .woodGrain || self == .custom) ? .additional : .included }

    /// On-screen approximations. Real swatches come from the local expert.
    var uiColor: UIColor {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
        switch self {
        case .classicWhite: return rgb(0.95, 0.945, 0.925)
        case .calicoLinen: return rgb(0.94, 0.92, 0.85)
        case .sliveredAlmond: return rgb(0.90, 0.85, 0.77)
        case .sandalWood: return rgb(0.80, 0.68, 0.55)
        case .driftwoodBeige: return rgb(0.55, 0.49, 0.38)
        case .hartfordGreen: return rgb(0.10, 0.25, 0.16)
        case .rideauBrown: return rgb(0.27, 0.19, 0.13)
        case .coastalGrey: return rgb(0.45, 0.45, 0.45)
        case .mineralBronze: return rgb(0.33, 0.27, 0.21)
        case .phantomBlack: return rgb(0.07, 0.07, 0.075)
        case .woodGrain: return rgb(0.62, 0.44, 0.27)
        case .custom: return UIColor(white: 0.9, alpha: 1)
        }
    }

    var color: Color { Color(uiColor) }

    /// The standard color closest to a color seen by the camera. Camera
    /// exposure makes brightness unreliable, so hue and saturation count
    /// more than lightness.
    static func closest(to seen: UIColor) -> FrameFinish {
        func lab(_ c: UIColor) -> SIMD3<Float> {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            let v = SIMD3<Float>(Float(r), Float(g), Float(b))
            let luma = max(0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z, 0.001)
            let chroma = v / luma
            return SIMD3(chroma.x - chroma.y, chroma.z - chroma.y, luma)
        }
        let target = lab(seen)
        return standard.min { a, b in
            func distance(_ f: FrameFinish) -> Float {
                let d = lab(f.uiColor) - target
                return d.x * d.x + d.y * d.y + 0.15 * d.z * d.z
            }
            return distance(a) < distance(b)
        } ?? .classicWhite
    }
}

// MARK: - Size bands

/// One of the website's height or width ranges.
struct SizeBand: Equatable {
    /// Lower and upper bounds in inches; nil lower means "or less".
    let lower: Float?
    let upper: Float
    let tag: PriceTag

    func title(_ unit: LengthUnit) -> String {
        func value(_ inches: Float) -> String {
            switch unit {
            case .inches: return Length.string(inches * Length.metresPerInch, unit: .inches).replacingOccurrences(of: " in", with: "\"")
            case .centimeters: return String(format: "%.0f cm", inches * 2.54)
            }
        }
        guard let lower else { return "\(value(upper)) or less" }
        return "\(value(lower)) to \(value(upper))"
    }

    static let heights = [
        SizeBand(lower: nil, upper: 84, tag: .included),
        SizeBand(lower: 84.25, upper: 96, tag: .additional),
        SizeBand(lower: 96.25, upper: 120, tag: .additional)
    ]
    static let widths = [
        SizeBand(lower: nil, upper: 36, tag: .included),
        SizeBand(lower: 36.125, upper: 48, tag: .additional)
    ]

    /// The band a measurement falls in, or nil if it's larger than all of them.
    static func band(for metres: Float, in bands: [SizeBand]) -> SizeBand? {
        let inches = Float(Length.eighths(metres)) / 8
        return bands.first { inches <= $0.upper }
    }
}

// MARK: - Configuration

/// One line of an order.
struct LineItem: Identifiable, Equatable {
    let label: String
    let value: String
    let tag: PriceTag?
    var id: String { label }
}

struct ScreenConfig: Equatable, Codable {
    var product: Product = .single
    /// Doors only: black vinyl corners hold the mesh in the tracks.
    var meshLock = false
    var closure: Closure = .latching
    var side: RetractSide = .left
    var finish: FrameFinish = .classicWhite
    /// "I'm unsure, I'll decide later." The preview keeps showing `finish`.
    var colorUndecided = false
    var mesh: MeshType = .insect
    var mount: Mount = .inside
    var motorControl: MotorControl = .remote
    /// Opening size in metres.
    var width: Float = 0.91
    var height: Float = 2.03
    /// 0 = fully retracted (or raised), 1 = fully closed (or lowered).
    var extent: Float = 1
    /// sRGB hex like "#E9E6DF", used when `finish == .custom`.
    var customColorHex: String = "#E9E6DF"
    /// True when the custom color was picked from the customer's own trim.
    var customMatchedToTrim = false

    /// Sizes the app can show or edit. Detection and products have their own limits.
    static let widthRange: ClosedRange<Float> = 0.3...12.2
    static let heightRange: ClosedRange<Float> = 0.3...5.0

    init() {}

    /// Decodes designs saved by older versions, which lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ScreenConfig()
        product = try c.decodeIfPresent(Product.self, forKey: .product) ?? defaults.product
        meshLock = try c.decodeIfPresent(Bool.self, forKey: .meshLock) ?? false
        closure = try c.decodeIfPresent(Closure.self, forKey: .closure) ?? defaults.closure
        side = try c.decodeIfPresent(RetractSide.self, forKey: .side) ?? defaults.side
        finish = try c.decodeIfPresent(FrameFinish.self, forKey: .finish) ?? defaults.finish
        colorUndecided = try c.decodeIfPresent(Bool.self, forKey: .colorUndecided) ?? false
        mesh = try c.decodeIfPresent(MeshType.self, forKey: .mesh) ?? defaults.mesh
        mount = try c.decodeIfPresent(Mount.self, forKey: .mount) ?? defaults.mount
        motorControl = try c.decodeIfPresent(MotorControl.self, forKey: .motorControl) ?? defaults.motorControl
        width = try c.decodeIfPresent(Float.self, forKey: .width) ?? defaults.width
        height = try c.decodeIfPresent(Float.self, forKey: .height) ?? defaults.height
        extent = try c.decodeIfPresent(Float.self, forKey: .extent) ?? defaults.extent
        customColorHex = try c.decodeIfPresent(String.self, forKey: .customColorHex) ?? defaults.customColorHex
        customMatchedToTrim = try c.decodeIfPresent(Bool.self, forKey: .customMatchedToTrim) ?? false
    }

    var hasMeshLock: Bool { meshLock && product.offersMeshLock }

    var frameUIColor: UIColor {
        finish == .custom ? (UIColor(hex: customColorHex) ?? finish.uiColor) : finish.uiColor
    }

    var frameColor: Color { Color(frameUIColor) }

    var finishTitle: String {
        finish == .custom ? "Custom Color \(customColorHex)" : finish.title
    }

    var colorTitle: String { colorUndecided ? "Undecided" : finishTitle }

    var screenTypeTitle: String {
        guard product.offersMeshLock else { return product.title }
        return hasMeshLock ? "Door Screen with Mesh Lock" : "Door Screen"
    }

    var heightBand: SizeBand? { product.usesSizeBands ? SizeBand.band(for: height, in: SizeBand.heights) : nil }
    var widthBand: SizeBand? { product.usesSizeBands ? SizeBand.band(for: width, in: SizeBand.widths) : nil }
    var fitsProduct: Bool { product.fits(width: width, height: height) }

    /// One line for the bar at the bottom of the screen.
    var summary: String {
        var parts = [colorUndecided ? "Color later" : finishTitle, mesh.title]
        if product.offersClosure { parts.append(closure.shortTitle) }
        if hasMeshLock { parts.append("Mesh lock") }
        if product.isMotorized { parts.append(motorControl.title) }
        return parts.joined(separator: " · ")
    }

    /// The order, line by line, as shown on Review Your Order and sent to the expert.
    func lineItems(unit: LengthUnit) -> [LineItem] {
        var items: [LineItem] = []
        func add(_ label: String, _ value: String, _ tag: PriceTag? = nil) {
            items.append(LineItem(label: label, value: value, tag: tag))
        }
        add("Product", product.title)
        if product.offersMeshLock {
            add("Type", hasMeshLock ? "Door Screen with Mesh Lock" : "Door Screen")
        }
        add("Measured size", Length.size(width: width, height: height, unit: unit))
        if let band = heightBand { add("Height", band.title(unit), band.tag) }
        if let band = widthBand { add("Width", band.title(unit), band.tag) }
        if !fitsProduct { add("Size", "Larger than standard, custom quote") }
        if product.hasRetractSide { add("Retracts to the", side.title.lowercased()) }
        if product.offersClosure { add("Closure", closure.title, closure.tag) }
        if product.isMotorized { add("Control", motorControl.title) }
        add("Mesh", mesh.title, mesh.tag)
        if colorUndecided {
            add("Color", "Undecided")
        } else {
            add("Color", finishTitle, finish.tag)
        }
        add("Mount", mount.title)
        return items
    }

    /// Line for the distributor when a custom color is requested.
    var customColorNote: String? {
        guard finish == .custom, !colorUndecided else { return nil }
        return customMatchedToTrim
            ? "Custom color match requested: \(customColorHex), sampled from the customer's trim with the phone camera. Please color-match on site."
            : "Custom color match requested: \(customColorHex), chosen on screen. Please color-match on site."
    }
}
