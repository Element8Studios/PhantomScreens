import Foundation

/// The rendering effects that cost the most. A preset sets all of them;
/// changing one by hand makes the mix "Custom".
struct VisualQuality: Codable, Equatable {
    enum Shadows: Int, Codable, CaseIterable, Identifiable, Comparable {
        /// Contact: soft shadows under the hardware. Full: also the key
        /// light's shadow cast onto the real wall.
        case off, contact, full

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .off: return "Off"
            case .contact: return "Soft"
            case .full: return "Full"
            }
        }
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    enum Reflections: Int, Codable, CaseIterable, Identifiable, Comparable {
        case off, standard, hdr

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .off: return "Off"
            case .standard: return "Standard"
            case .hdr: return "HDR"
            }
        }
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    enum CameraEffects: Int, Codable, CaseIterable, Identifiable, Comparable {
        /// Motion blur matches the camera's blur when the phone moves;
        /// cinematic adds depth of field and film grain.
        case off, motionBlur, cinematic

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .off: return "Off"
            case .motionBlur: return "Motion blur"
            case .cinematic: return "Cinematic"
            }
        }
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// The screen hides behind real things in front of it (LiDAR).
    var occlusion: Bool
    var shadows: Shadows
    var reflections: Reflections
    var effects: CameraEffects

    /// Each setting no higher than `cap`'s: used to turn effects down while
    /// the phone is hot or in Low Power Mode.
    func capped(by cap: VisualQuality) -> VisualQuality {
        VisualQuality(occlusion: occlusion && cap.occlusion,
                      shadows: min(shadows, cap.shadows),
                      reflections: min(reflections, cap.reflections),
                      effects: min(effects, cap.effects))
    }
}

enum QualityPreset: String, CaseIterable, Identifiable {
    case low, medium, high, cinematic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .cinematic: return "Cinematic"
        }
    }

    var symbol: String {
        switch self {
        case .low: return "leaf"
        case .medium: return "circle.lefthalf.filled"
        case .high: return "sparkle"
        case .cinematic: return "film"
        }
    }

    var settings: VisualQuality {
        switch self {
        case .low:
            return VisualQuality(occlusion: false, shadows: .off, reflections: .off, effects: .off)
        case .medium:
            return VisualQuality(occlusion: true, shadows: .contact, reflections: .standard, effects: .off)
        case .high:
            return VisualQuality(occlusion: true, shadows: .full, reflections: .standard, effects: .motionBlur)
        case .cinematic:
            return VisualQuality(occlusion: true, shadows: .full, reflections: .hdr, effects: .cinematic)
        }
    }

    /// The preset these settings match, or nil for a custom mix.
    static func matching(_ settings: VisualQuality) -> QualityPreset? {
        allCases.first { $0.settings == settings }
    }
}
