import SwiftUI
import UIKit

// MARK: - Colors

extension UIColor {
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

// MARK: - Lengths

enum LengthUnit: String, CaseIterable, Identifiable {
    case inches, centimeters
    var id: String { rawValue }
    var short: String { self == .inches ? "in" : "cm" }
}

enum Length {
    static let metresPerInch: Float = 0.0254
    /// Screen doors are specified to the nearest eighth of an inch.
    static let eighth: Float = metresPerInch / 8

    static func eighths(_ metres: Float) -> Int {
        Int((metres / eighth).rounded())
    }

    static func string(_ metres: Float, unit: LengthUnit) -> String {
        switch unit {
        case .centimeters:
            return String(format: "%.1f cm", metres * 100)
        case .inches:
            let total = max(eighths(metres), 0)
            let whole = total / 8
            let fractions = ["", "⅛", "¼", "⅜", "½", "⅝", "¾", "⅞"]
            let remainder = fractions[total % 8]
            return remainder.isEmpty ? "\(whole) in" : "\(whole) \(remainder) in"
        }
    }

    static func size(width: Float, height: Float, unit: LengthUnit) -> String {
        let w = string(width, unit: unit)
        let h = string(height, unit: unit)
        let suffix = " " + unit.short
        return w.replacingOccurrences(of: suffix, with: "") + " × " + h
    }
}

extension Color {
    /// Measuring-tape amber used for AR guides.
    static let phantomGuide = Color(red: 1.0, green: 0.76, blue: 0.29)
}

// MARK: - Rendering options

enum PaintGloss: String, CaseIterable, Identifiable {
    case matte, satin, gloss

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Physically based parameters for powder-coated aluminium. Paint is a
    /// dielectric, so it is never metallic; gloss comes from a clear coat.
    var metallic: Float { 0 }
    var roughness: Float {
        switch self { case .matte: return 0.75; case .satin: return 0.45; case .gloss: return 0.28 }
    }
    var clearcoat: Float {
        switch self { case .matte: return 0; case .satin: return 0.4; case .gloss: return 1 }
    }
    var clearcoatRoughness: Float {
        switch self { case .matte: return 0.5; case .satin: return 0.25; case .gloss: return 0.05 }
    }
}

enum ColorTemperature {
    /// Approximate RGB (0...1) for a color temperature in kelvin (1000–40000 K).
    static func rgb(kelvin: Float) -> SIMD3<Float> {
        let t = min(max(kelvin, 1000), 40000) / 100
        let r: Float = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g: Float = t <= 66
            ? 99.4708025861 * log(t) - 161.1195681661
            : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b: Float = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        return SIMD3(r, g, b).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 255)) / 255
    }
}
