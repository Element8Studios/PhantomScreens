import RealityKit
import UIKit

/// A line the user can drag a pull bar along, in the entity's local space.
struct DragTrack {
    var start: SIMD3<Float>
    var end: SIMD3<Float>
    var bar: SIMD3<Float>
}

/// A procedurally built Phantom-style retractable screen.
///
/// Local frame matches `Opening`: origin at the centre of the opening,
/// +X right, +Y up, +Z toward the room. Surface mount: the opening is the
/// mesh area and the hardware sits around it, on the trim. Inside mount:
/// everything fits within the jamb, so the mesh area is smaller (see
/// `reach(for:)`). As installed:
/// - Doors: an upright housing (flat back, angled front corners) on the
///   retract side, thin top and bottom tracks with an end clip, and a pull bar
///   with a D-shaped handle. No jamb on the far side; the bar closes against
///   the trim.
/// - Oversized door screens: the same, with a heavier housing and bar; two
///   screens meeting in the middle past 15 ft.
/// - Windows: a round-fronted housing across the top and thin side channels.
/// - Motorized screens: a headbox across the top (or a slim slot when it's
///   recessed into the ceiling), side tracks or stainless cables to the floor,
///   and a bottom bar that lowers inside the opening. Motorized Vinyl Screens
///   have a vinyl panel (fabric border, clear vinyl, optional mesh band)
///   instead of mesh.
///
/// The static hardware is rebuilt only when size, product or appearance
/// change. Opening and closing only moves the bars and rescales the screen
/// quads; no meshes are built per frame.
final class ScreenDoorEntity: Entity {
    private(set) var config: ScreenConfig
    private(set) var tracks: [DragTrack] = []
    private(set) var gloss: PaintGloss = .gloss
    private(set) var castsShadows = true
    /// Per-channel gain from matching the room's white (see WhiteMatch.swift).
    private(set) var colorGain = SIMD3<Float>(repeating: 1)
    private(set) var extent: Float = 1

    private let content = Entity()
    private let staticRoot = Entity()
    private var leaves: [Leaf] = []
    /// Every part painted in the frame finish, so color changes repaint in place.
    private var painted: [ModelEntity] = []
    /// Points on the flat front of the painted hardware (in this entity's
    /// space), where white balance samples the rendered frame.
    private(set) var paintSamplePoints: [SIMD3<Float>] = []
    private var samples: [SIMD3<Float>] = []
    /// Rectangles (min x, min y, max x, max y in this entity's space) the
    /// screen and its bars cover right now.
    private var coverage: [SIMD4<Float>] = []
    /// The mesh area, same layout. Around it is hardware or wall.
    private var meshArea = SIMD4<Float>(repeating: 0)

    // Hardware sizes in metres, from the installed product.
    static let windowHousing: Float = 0.065     // window housing height and depth
    static let trackThickness: Float = 0.012
    static let trackDepth: Float = 0.024
    static let barWidth: Float = 0.032
    static let barDepth: Float = 0.034
    static let headbox: Float = 0.13            // motorized headbox, height and depth
    static let headboxChamfer: Float = 0.03
    static let sideTrackWidth: Float = 0.045    // motorized side tracks
    static let sideTrackDepth: Float = 0.06
    static let bottomBar: Float = 0.05
    static let cableGuide: Float = 0.025        // motorized cables, past each side of the screen
    static let recessedSlot: Float = 0.014      // visible ceiling slot of a recessed headbox
    static let vinylBorder: Float = 0.09        // fabric border around a vinyl panel
    static let vinylBand: Float = 0.35          // mesh band below the vinyl
    /// One oversized screen covers up to 15 ft; wider openings get two.
    static let oversizedSingleMax: Float = 15 * 0.3048

    /// Door housing and pull bar sizes.
    struct DoorHardware: Equatable {
        var housingWidth: Float
        var housingDepth: Float
        var chamfer: Float
        var barWidth: Float
        var barDepth: Float

        static let standard = DoorHardware(housingWidth: 0.055, housingDepth: 0.06, chamfer: 0.014,
                                           barWidth: 0.032, barDepth: 0.034)
        static let oversized = DoorHardware(housingWidth: 0.075, housingDepth: 0.085, chamfer: 0.018,
                                            barWidth: 0.045, barDepth: 0.045)
    }

    static func hardware(for config: ScreenConfig) -> DoorHardware {
        config.product == .oversized ? .oversized : .standard
    }

    /// Doors with a housing on both sides.
    static func hasTwoHousings(_ config: ScreenConfig) -> Bool {
        config.product == .double || (config.product == .oversized && config.width > oversizedSingleMax)
    }

    /// How far the hardware reaches past each edge of the mesh area.
    struct Reach {
        var left: Float
        var right: Float
        var top: Float
        var bottom: Float
    }

    static func reach(for config: ScreenConfig) -> Reach {
        let track = trackThickness
        switch config.product {
        case .single, .sliding, .oversized, .double:
            let hw = hardware(for: config)
            if hasTwoHousings(config) {
                return Reach(left: hw.housingWidth, right: hw.housingWidth, top: track, bottom: track)
            }
            // The far side has the closed pull bar and its end clip.
            let far = hw.barWidth + 0.015
            return config.side == .left
                ? Reach(left: hw.housingWidth, right: far, top: track, bottom: track)
                : Reach(left: far, right: hw.housingWidth, top: track, bottom: track)
        case .window:
            return Reach(left: track, right: track, top: windowHousing, bottom: barWidth + 0.005)
        case .motorized, .motorizedVinyl:
            let side = config.guide == .cables ? cableGuide : sideTrackWidth
            let top = config.recessedHeadbox ? recessedSlot : headbox
            return Reach(left: side, right: side, top: top, bottom: 0)
        }
    }

    /// How far the hardware stands proud of the wall when mounted outside.
    static func mountDepth(for config: ScreenConfig) -> Float {
        switch config.product {
        case .window: return windowHousing
        case .motorized, .motorizedVinyl:
            // Recessed, only the guides stand off the wall.
            guard config.recessedHeadbox else { return headbox }
            return config.guide == .cables ? 0.04 : sideTrackDepth
        default: return hardware(for: config).housingDepth
        }
    }
    /// World metres covered by one repeat of the mesh texture.
    private static let tile: Float = 0.025

    private enum HandleStyle { case grip, tab, none }

    /// One travelling screen: its mesh quad (or vinyl panel parts), pull
    /// bar, handle and mesh-lock corners.
    private struct Leaf {
        /// Where the screen leaves the housing, along the travel axis.
        var origin: Float
        /// +1 or −1 along the travel axis.
        var direction: Float
        /// Travel from fully retracted to fully closed.
        var travel: Float
        /// Size across the direction of travel.
        var span: Float
        /// True for side-to-side travel, false for top-to-bottom.
        var horizontal: Bool
        /// Bar thickness along the travel axis, and its depth.
        var barWidth: Float
        var barDepth: Float
        var screen: ModelEntity
        var bar: ModelEntity
        var handle: Entity
        var corners: [ModelEntity]
        /// Motorized vinyl panel parts, in place of the mesh quad.
        var vinyl: VinylParts?
    }

    /// A vinyl panel: fabric border, clear vinyl, and (optionally) a mesh band
    /// above the bottom border.
    private struct VinylParts {
        var left: ModelEntity
        var right: ModelEntity
        var top: ModelEntity
        var bottom: ModelEntity
        var clear: ModelEntity
        var band: ModelEntity?
        var all: [ModelEntity] { [left, right, top, bottom, clear] + (band.map { [$0] } ?? []) }
    }

    /// Where the screen sits front to back, in this entity's space.
    var screenPlaneZ: Float { content.position.z }

    /// True where the screen (or one of its bars) covers the opening at
    /// this point (this entity's space).
    func isCovered(x: Float, y: Float) -> Bool {
        func inside(_ r: SIMD4<Float>) -> Bool { x >= r.x && x <= r.z && y >= r.y && y <= r.w }
        return !inside(meshArea) || coverage.contains(where: inside)
    }


    required init() {
        config = ScreenConfig()
        super.init()
        addChild(content)
        content.addChild(staticRoot)
        rebuild()
    }

    /// Starts at the configuration's screen position. After that the position
    /// only changes through `setExtent` (dragging or animating), never when
    /// an option changes.
    convenience init(config: ScreenConfig) {
        self.init()
        update(config)
        setExtent(config.extent)
    }

    func update(_ newConfig: ScreenConfig) {
        let old = config
        config = newConfig
        config.extent = extent
        if Self.shape(of: newConfig) != Self.shape(of: old) {
            rebuild()
            return
        }
        // Colour and mesh changes repaint in place: no rebuild, no flicker.
        if newConfig.finish != old.finish || newConfig.customColorHex != old.customColorHex {
            repaint()
        }
        if newConfig.mesh != old.mesh || newConfig.meshColor != old.meshColor {
            // Layout picks up the new weave (and sizes its texture).
            layoutLeaves()
        }
    }

    /// The parts of a configuration that change geometry.
    private static func shape(of config: ScreenConfig) -> ScreenConfig {
        var c = config
        c.extent = 0
        c.finish = .classicWhite
        c.customColorHex = ""
        c.customMatchedToTrim = false
        // Meshes just swap material; a vinyl panel's layout is geometry.
        c.mesh = .insect
        c.meshColor = .black
        c.colorUndecided = false
        c.closure = .latching
        c.motorControl = .remote
        c.motor = .electric
        return c
    }

    func setAppearance(gloss: PaintGloss, castsShadows: Bool, colorGain: SIMD3<Float>? = nil) {
        let gain = colorGain ?? self.colorGain
        guard gloss != self.gloss || castsShadows != self.castsShadows || gain != self.colorGain else { return }
        let shadowsChanged = castsShadows != self.castsShadows
        self.gloss = gloss
        self.castsShadows = castsShadows
        self.colorGain = gain
        if shadowsChanged { rebuild() } else { repaint() }
    }

    private func repaint() {
        let material = frameMaterial()
        for part in painted { part.model?.materials = [material] }
    }

    // MARK: - Materials

    /// Powder-coat paint with a clear coat, so it picks up ARKit's
    /// camera-built environment probes as reflections. Wood grain uses a
    /// procedural grain texture under the same clear coat.
    private func frameMaterial() -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        let isWood = config.finish == .woodGrain
        let base = isWood ? UIColor.white : config.frameUIColor
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getRed(&r, green: &g, blue: &b, alpha: &a)
        let tint = UIColor(red: min(r * CGFloat(colorGain.x), 1),
                           green: min(g * CGFloat(colorGain.y), 1),
                           blue: min(b * CGFloat(colorGain.z), 1), alpha: 1)
        if isWood, let wood = Self.woodTexture {
            material.baseColor = .init(tint: tint, texture: .init(wood))
        } else {
            material.baseColor = .init(tint: tint)
        }
        material.metallic = .init(floatLiteral: gloss.metallic)
        material.roughness = .init(floatLiteral: isWood ? max(gloss.roughness, 0.4) : gloss.roughness)
        material.clearcoat = .init(floatLiteral: gloss.clearcoat)
        material.clearcoatRoughness = .init(floatLiteral: gloss.clearcoatRoughness)
        return material
    }

    /// Rich black, semi-gloss: the mesh-lock corners and a black vinyl
    /// panel's border. (Very dark, smoother paint so highlights stay tight
    /// instead of washing it grey.)
    private static let vinylMaterial = fabric(.black)

    private static func fabric(_ color: VinylColor) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color.uiColor)
        material.roughness = .init(floatLiteral: color == .black ? 0.42 : 0.5)
        material.specular = .init(floatLiteral: 0.35)
        material.clearcoat = .init(floatLiteral: 0.25)
        material.clearcoatRoughness = .init(floatLiteral: 0.3)
        return material
    }

    /// Clear vinyl: see-through and glossy, with a gentle ripple in the
    /// surface so reflections bend and slide as you move, like real vinyl.
    private static let clearVinylMaterial: PhysicallyBasedMaterial = {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(red: 0.5, green: 0.55, blue: 0.57, alpha: 1))
        material.roughness = .init(floatLiteral: 0.03)
        material.specular = .init(floatLiteral: 1)
        material.clearcoat = .init(floatLiteral: 1)
        material.clearcoatRoughness = .init(floatLiteral: 0.01)
        if let ripple = rippleTexture {
            material.normal = .init(texture: .init(ripple))
        }
        material.blending = .transparent(opacity: 0.2)
        return material
    }()

    /// Metres covered by one repeat of the vinyl ripple.
    private static let ripplePeriod: Float = 1.1

    /// A tiling normal map of soft, uneven waves.
    private static let rippleTexture: TextureResource? = {
        let n = 256
        // (cycles across, cycles down, amplitude, phase); whole cycles tile.
        let waves: [(Float, Float, Float, Float)] = [
            (1, 3, 1, 0.3), (2, -1, 0.7, 1.9), (3, 5, 0.35, 4.1), (-4, 2, 0.25, 2.6), (5, 7, 0.12, 0.8),
        ]
        var bytes = [UInt8](repeating: 255, count: n * n * 4)
        let strength: Float = 0.012
        let tau: Float = 2 * Float.pi
        // Simple typed steps: one long expression here was too slow for
        // the compiler to type-check.
        func byte(_ value: Float) -> UInt8 {
            let scaled: Float = (value * 0.5 + 0.5) * 255
            return UInt8(min(max(scaled, 0), 255))
        }
        for y in 0..<n {
            for x in 0..<n {
                let u: Float = Float(x) / Float(n)
                let v: Float = Float(y) / Float(n)
                var dx: Float = 0
                var dy: Float = 0
                for wave in waves {
                    let angle: Float = tau * (wave.0 * u + wave.1 * v) + wave.3
                    let slope: Float = cos(angle) * wave.2 * tau
                    dx += slope * wave.0
                    dy += slope * wave.1
                }
                let tilt = SIMD3<Float>(-dx * strength, -dy * strength, 1)
                let normal: SIMD3<Float> = simd_normalize(tilt)
                let i = (y * n + x) * 4
                bytes[i] = byte(normal.x)
                bytes[i + 1] = byte(normal.y)
                bytes[i + 2] = byte(normal.z)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return nil }
        return try? TextureResource.generate(from: image, options: .init(semantic: .normal))
    }()

    /// Stainless cable and chrome floor brackets (not painted).
    private static let steelMaterial: PhysicallyBasedMaterial = {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(white: 0.78, alpha: 1))
        material.metallic = .init(floatLiteral: 1)
        material.roughness = .init(floatLiteral: 0.3)
        return material
    }()

    private static let chromeMaterial: PhysicallyBasedMaterial = {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(white: 0.92, alpha: 1))
        material.metallic = .init(floatLiteral: 1)
        material.roughness = .init(floatLiteral: 0.08)
        return material
    }()

    // MARK: - Static hardware

    private func rebuild() {
        painted = []
        for child in Array(staticRoot.children) { child.removeFromParent() }
        for leaf in leaves {
            leaf.screen.removeFromParent()
            leaf.bar.removeFromParent()
            leaf.handle.removeFromParent()
            leaf.corners.forEach { $0.removeFromParent() }
            leaf.vinyl?.all.forEach { $0.removeFromParent() }
        }
        leaves = []

        // The rectangle is the measured opening.
        // - Outside (surface) mount: the hardware sits around it, on the
        //   face of the trim or wall, and the mesh fills the opening.
        // - Inside mount: everything fits within the jamb, set back just
        //   behind the trim, so the mesh area is smaller than the opening.
        let depth = Self.mountDepth(for: config)
        var w = config.width
        var h = config.height
        if config.mount == .inside {
            let r = Self.reach(for: config)
            w = max(config.width - r.left - r.right, 0.1)
            h = max(config.height - r.top - r.bottom, 0.1)
            content.position = SIMD3((r.left - r.right) / 2, (r.bottom - r.top) / 2, -depth / 2 - 0.005)
        } else {
            content.position = SIMD3(0, 0, depth / 2 + 0.01)
        }

        let frame = frameMaterial()
        samples = []
        let p = content.position
        meshArea = SIMD4(p.x - w / 2, p.y - h / 2, p.x + w / 2, p.y + h / 2)

        switch config.product {
        case .single, .sliding:
            buildSingle(.standard, w: w, h: h, frame: frame)
        case .double:
            buildDouble(.standard, w: w, h: h, frame: frame)
        case .oversized:
            if Self.hasTwoHousings(config) {
                buildDouble(.oversized, w: w, h: h, frame: frame)
            } else {
                buildSingle(.oversized, w: w, h: h, frame: frame)
            }
        case .window:
            buildWindow(w: w, h: h, frame: frame)
        case .motorized, .motorizedVinyl:
            buildMotorized(w: w, h: h, frame: frame)
        }

        paintSamplePoints = samples.map { $0 + content.position }

        // Keep the screen where it was: a new product or size rebuilds the
        // hardware but doesn't move the screen.
        layoutLeaves()
    }

    /// Housing on the retract side, thin top and bottom tracks, end clips
    /// where the closed bar latches, and no jamb on the far side.
    private func buildSingle(_ hw: DoorHardware, w: Float, h: Float, frame: PhysicallyBasedMaterial) {
        let s: Float = config.side == .left ? 1 : -1
        let tt = Self.trackThickness
        let td = Self.trackDepth
        let bw = hw.barWidth
        // Tracks sit toward the back of the housing.
        let trackZ = -hw.housingDepth / 2 + td / 2
        let housing = Self.chamferedMesh(length: h + 2 * tt + 0.01, width: hw.housingWidth,
                                         depth: hw.housingDepth, chamfer: hw.chamfer, vertical: true)
        let housingX = s * (-w / 2 - hw.housingWidth / 2)
        staticPart(housing, SIMD3(housingX, 0, 0), frame)
        samples += [SIMD3(housingX, h * 0.25, hw.housingDepth / 2), SIMD3(housingX, -h * 0.25, hw.housingDepth / 2)]
        // Tracks run from the housing to just past the far edge, where the closed bar latches.
        let trackLength = w + bw + 0.012
        let trackX = s * (-w / 2 + trackLength / 2)
        staticBox(SIMD3(trackLength, tt, td), SIMD3(trackX, h / 2 + tt / 2, trackZ), frame)
        staticBox(SIMD3(trackLength, tt, td), SIMD3(trackX, -h / 2 - tt / 2, trackZ), frame)
        let clipX = s * (w / 2 + bw + 0.006)
        staticBox(SIMD3(0.018, 0.022, 0.028), SIMD3(clipX, h / 2 + tt / 2, trackZ + 0.004), frame)
        staticBox(SIMD3(0.018, 0.022, 0.028), SIMD3(clipX, -h / 2 - tt / 2, trackZ + 0.004), frame)
        addLeaf(origin: s * (-w / 2), direction: s, travel: w + bw, span: h, horizontal: true,
                bar: SIMD2(bw, hw.barDepth), handle: .grip, frame: frame)
    }

    /// Housings on both sides; the two bars meet in the middle when closed.
    private func buildDouble(_ hw: DoorHardware, w: Float, h: Float, frame: PhysicallyBasedMaterial) {
        let tt = Self.trackThickness
        let td = Self.trackDepth
        let trackZ = -hw.housingDepth / 2 + td / 2
        let housing = Self.chamferedMesh(length: h + 2 * tt + 0.01, width: hw.housingWidth,
                                         depth: hw.housingDepth, chamfer: hw.chamfer, vertical: true)
        for side: Float in [-1, 1] {
            let x = side * (w / 2 + hw.housingWidth / 2)
            staticPart(housing, SIMD3(x, 0, 0), frame)
            samples += [SIMD3(x, h * 0.25, hw.housingDepth / 2), SIMD3(x, -h * 0.25, hw.housingDepth / 2)]
        }
        staticBox(SIMD3(w, tt, td), SIMD3(0, h / 2 + tt / 2, trackZ), frame)
        staticBox(SIMD3(w, tt, td), SIMD3(0, -h / 2 - tt / 2, trackZ), frame)
        let bar = SIMD2(hw.barWidth, hw.barDepth)
        addLeaf(origin: -w / 2, direction: 1, travel: w / 2, span: h, horizontal: true, bar: bar, handle: .grip, frame: frame)
        addLeaf(origin: w / 2, direction: -1, travel: w / 2, span: h, horizontal: true, bar: bar, handle: .grip, frame: frame)
    }

    /// Round-fronted housing across the top and thin side channels.
    private func buildWindow(w: Float, h: Float, frame: PhysicallyBasedMaterial) {
        let tt = Self.trackThickness
        let td = Self.trackDepth
        let bw = Self.barWidth
        let wh = Self.windowHousing
        let trackZ = -wh / 2 + td / 2
        staticPart(Self.windowHousingMesh(length: w + 2 * tt + 0.01), SIMD3(0, h / 2 + wh / 2, 0), frame)
        samples += [SIMD3(-w * 0.25, h / 2 + wh / 2, wh / 2), SIMD3(w * 0.25, h / 2 + wh / 2, wh / 2)]
        // Side channels run down past the bottom edge, where the closed bar rests.
        let channelLength = h + bw + 0.01
        let channelY = h / 2 - channelLength / 2
        staticBox(SIMD3(tt, channelLength, td), SIMD3(-w / 2 - tt / 2, channelY, trackZ), frame)
        staticBox(SIMD3(tt, channelLength, td), SIMD3(w / 2 + tt / 2, channelY, trackZ), frame)
        addLeaf(origin: h / 2, direction: -1, travel: h + bw, span: w, horizontal: false,
                bar: SIMD2(bw, Self.barDepth), handle: .tab, frame: frame)
    }

    /// Headbox across the top (or a slim slot when it's recessed into the
    /// ceiling), side tracks or stainless cables down to the floor, and a
    /// bottom bar that comes to rest on the floor inside the opening.
    private func buildMotorized(w: Float, h: Float, frame: PhysicallyBasedMaterial) {
        let hb = Self.headbox
        let cables = config.guide == .cables
        let side = cables ? Self.cableGuide : Self.sideTrackWidth
        let depth = Self.mountDepth(for: config)
        let length = w + 2 * side + 0.02
        if config.recessedHeadbox {
            let slot = Self.recessedSlot
            staticBox(SIMD3(length, slot, depth), SIMD3(0, h / 2 + slot / 2, 0), frame)
            samples += [SIMD3(-w * 0.25, h / 2 + slot / 2, depth / 2), SIMD3(w * 0.25, h / 2 + slot / 2, depth / 2)]
        } else {
            let headbox = Self.chamferedMesh(length: length, width: hb, depth: hb,
                                             chamfer: Self.headboxChamfer, vertical: false)
            staticPart(headbox, SIMD3(0, h / 2 + hb / 2, 0), frame)
            samples += [SIMD3(-w * 0.25, h / 2 + hb / 2, hb / 2), SIMD3(w * 0.25, h / 2 + hb / 2, hb / 2)]
        }
        let barDepth = Self.sideTrackDepth * 0.8
        if cables {
            // A cable just past each end of the screen, through the bottom
            // bar, down to a chrome bracket on the floor. The bar rests on
            // the brackets.
            let bracket = SIMD3<Float>(0.026, 0.02, 0.05)
            let cableX = w / 2 + side / 2
            let cableZ: Float = -0.012
            for s: Float in [-1, 1] {
                metalPart(Self.boxMesh(SIMD3(0.004, h - bracket.y, 0.004)),
                          SIMD3(s * cableX, bracket.y / 2, cableZ), Self.steelMaterial)
                metalPart(Self.boxMesh(bracket), SIMD3(s * cableX, -h / 2 + bracket.y / 2, cableZ), Self.chromeMaterial)
            }
            addLeaf(origin: h / 2, direction: -1, travel: h - bracket.y, span: w, horizontal: false,
                    bar: SIMD2(Self.bottomBar, barDepth), handle: .none, frame: frame, barOverhang: 2 * side)
        } else {
            let tdepth = Self.sideTrackDepth
            let trackZ = -depth / 2 + tdepth / 2
            staticBox(SIMD3(side, h, tdepth), SIMD3(-w / 2 - side / 2, 0, trackZ), frame)
            staticBox(SIMD3(side, h, tdepth), SIMD3(w / 2 + side / 2, 0, trackZ), frame)
            addLeaf(origin: h / 2, direction: -1, travel: h, span: w, horizontal: false,
                    bar: SIMD2(Self.bottomBar, barDepth), handle: .none, frame: frame)
        }
    }

    /// Unpainted hardware (keeps its own finish when the colour changes).
    private func metalPart(_ mesh: MeshResource, _ position: SIMD3<Float>, _ material: PhysicallyBasedMaterial) {
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = position
        addShadow(to: entity)
        staticRoot.addChild(entity)
    }

    private func staticBox(_ size: SIMD3<Float>, _ position: SIMD3<Float>, _ material: PhysicallyBasedMaterial) {
        guard size.x > 0, size.y > 0, size.z > 0 else { return }
        staticPart(Self.boxMesh(size), position, material)
    }

    private func staticPart(_ mesh: MeshResource, _ position: SIMD3<Float>, _ material: PhysicallyBasedMaterial) {
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = position
        addShadow(to: entity)
        painted.append(entity)
        staticRoot.addChild(entity)
    }

    /// - Parameter barOverhang: extra bar length past the screen's edges.
    private func addLeaf(origin: Float, direction: Float, travel: Float, span: Float, horizontal: Bool,
                         bar barDimensions: SIMD2<Float>, handle style: HandleStyle, frame: PhysicallyBasedMaterial,
                         barOverhang: Float = 0) {
        let bw = barDimensions.x
        let bd = barDimensions.y
        let barSize = horizontal ? SIMD3(bw, span + barOverhang, bd) : SIMD3(span + barOverhang, bw, bd)
        let screen = ModelEntity()
        let bar = ModelEntity(mesh: Self.boxMesh(barSize), materials: [frame])
        addShadow(to: bar)
        painted.append(bar)

        // Handle: a D-shaped grip standing off the bar (doors), a short pull
        // tab (windows), or none (motorized).
        let handle = Entity()
        switch style {
        case .grip:
            let grip = ModelEntity(mesh: Self.boxMesh(SIMD3(0.018, 0.15, 0.014)), materials: [frame])
            grip.position = SIMD3(0, 0, 0.026)
            let upper = ModelEntity(mesh: Self.boxMesh(SIMD3(0.018, 0.02, 0.026)), materials: [frame])
            upper.position = SIMD3(0, 0.065, 0.013)
            let lower = ModelEntity(mesh: Self.boxMesh(SIMD3(0.018, 0.02, 0.026)), materials: [frame])
            lower.position = SIMD3(0, -0.065, 0.013)
            for part in [grip, upper, lower] {
                addShadow(to: part)
                handle.addChild(part)
                painted.append(part)
            }
        case .tab:
            let tab = ModelEntity(mesh: Self.boxMesh(SIMD3(0.09, 0.016, 0.02)), materials: [frame])
            tab.position = SIMD3(0, -0.012, 0.018)
            addShadow(to: tab)
            handle.addChild(tab)
            painted.append(tab)
        case .none:
            break
        }

        // Mesh lock: black vinyl triangles in the two mesh corners at the
        // pull bar (doors only); the housing end has none.
        var corners: [ModelEntity] = []
        if config.hasMeshLock, horizontal {
            for _ in 0..<2 {
                let corner = ModelEntity(mesh: Self.cornerMesh, materials: [Self.vinylMaterial])
                content.addChild(corner)
                corners.append(corner)
            }
        }

        var vinyl: VinylParts?
        if config.isVinyl, !horizontal {
            func part(_ material: Material) -> ModelEntity {
                let entity = ModelEntity(mesh: Self.unitQuad, materials: [material])
                content.addChild(entity)
                return entity
            }
            let border = Self.fabric(config.vinylColor)
            vinyl = VinylParts(left: part(border), right: part(border), top: part(border), bottom: part(border),
                               clear: part(Self.clearVinylMaterial),
                               band: config.vinyl == .meshBand
                                   ? part(Self.material(for: .insect, color: config.meshColor)) : nil)
        }

        content.addChild(screen)
        content.addChild(bar)
        content.addChild(handle)
        leaves.append(Leaf(origin: origin, direction: direction, travel: travel, span: span,
                           horizontal: horizontal, barWidth: bw, barDepth: bd,
                           screen: screen, bar: bar, handle: handle, corners: corners, vinyl: vinyl))
    }

    // MARK: - Moving parts

    func setExtent(_ value: Float) {
        extent = min(max(value, 0), 1)
        config.extent = extent
        layoutLeaves()
    }

    private func layoutLeaves() {
        let weave = Self.material(for: config.mesh, color: config.meshColor)
        // Tracks are in this entity's space; the parts are offset by the mount.
        let offset = content.position
        tracks = []
        coverage = []
        for leaf in leaves {
            let bw = leaf.barWidth
            let handleZ = leaf.barDepth / 2
            let length = extent * leaf.travel
            // Retracted, the bar sits against the housing just outside the
            // rectangle; closed, the mesh fills the rectangle.
            let barAt = leaf.origin + leaf.direction * (length - bw / 2)
            let screenLength = max(length - bw, 0)
            let screenAt = leaf.origin + leaf.direction * screenLength / 2

            let (screenW, screenH) = leaf.horizontal ? (screenLength, leaf.span) : (leaf.span, screenLength)
            let visible = screenW > 0.005 && screenH > 0.005
            if let vinyl = leaf.vinyl {
                leaf.screen.isEnabled = false
                layoutVinyl(vinyl, leaf: leaf, shown: screenLength)
            } else if visible {
                // One unit quad, scaled; the weave keeps its real size by
                // scaling the texture instead of building a new mesh.
                if leaf.screen.model == nil {
                    leaf.screen.model = ModelComponent(mesh: Self.unitQuad, materials: [])
                }
                leaf.screen.model?.materials = [Self.tiled(weave, width: screenW, height: screenH)]
                leaf.screen.scale = SIMD3(screenW, screenH, 1)
                leaf.screen.isEnabled = true
            } else {
                leaf.screen.isEnabled = false
            }

            if leaf.horizontal {
                leaf.screen.position = SIMD3(screenAt, 0, 0)
                leaf.bar.position = SIMD3(barAt, 0, 0)
                leaf.handle.position = SIMD3(barAt, 0, handleZ)
                tracks.append(DragTrack(start: offset + SIMD3(leaf.origin, 0, 0),
                                        end: offset + SIMD3(leaf.origin + leaf.direction * leaf.travel, 0, 0),
                                        bar: offset + SIMD3(barAt, 0, 0)))
                let a = leaf.origin, b = leaf.origin + leaf.direction * length
                coverage.append(SIMD4(min(a, b) + offset.x, -leaf.span / 2 + offset.y,
                                      max(a, b) + offset.x, leaf.span / 2 + offset.y))
            } else {
                leaf.screen.position = SIMD3(0, screenAt, 0)
                leaf.bar.position = SIMD3(0, barAt, 0)
                leaf.handle.position = SIMD3(0, barAt, handleZ)
                tracks.append(DragTrack(start: offset + SIMD3(0, leaf.origin, 0),
                                        end: offset + SIMD3(0, leaf.origin + leaf.direction * leaf.travel, 0),
                                        bar: offset + SIMD3(0, barAt, 0)))
                let a = leaf.origin, b = leaf.origin + leaf.direction * length
                coverage.append(SIMD4(-leaf.span / 2 + offset.x, min(a, b) + offset.y,
                                      leaf.span / 2 + offset.x, max(a, b) + offset.y))
            }

            // Mesh-lock corners follow the top and bottom of the mesh's
            // leading edge, against the pull bar.
            if !leaf.corners.isEmpty {
                let size = min(0.07, min(screenW, screenH) / 3)
                let cx = leaf.horizontal ? screenAt : 0
                let cy = leaf.horizontal ? 0 : screenAt
                let signs: [(Float, Float)] = [(leaf.direction, 1), (leaf.direction, -1)]
                for (corner, sign) in zip(leaf.corners, signs) {
                    corner.isEnabled = visible && size > 0.01
                    corner.position = SIMD3(cx + sign.0 * screenW / 2, cy + sign.1 * screenH / 2, 0.001)
                    // The unit triangle points into +x/+y; flip it toward the mesh.
                    corner.scale = SIMD3(-sign.0 * size, -sign.1 * size, 1)
                }
            }
        }
    }

    /// Places a vinyl panel's parts for `shown` metres let down. The panel
    /// unrolls from the top, so what shows is its lowest `shown` metres.
    private func layoutVinyl(_ vinyl: VinylParts, leaf: Leaf, shown: Float) {
        // The most that ever shows: the bar takes the rest of the travel.
        let full = max(leaf.travel - leaf.barWidth, 0.01)
        let w = leaf.span
        let border = min(Self.vinylBorder, w / 6, full / 6)
        let band = vinyl.band == nil ? 0 : min(Self.vinylBand, (full - 2 * border) * 0.3)
        let innerW = max(w - 2 * border, 0.01)
        // Panel heights measured up from its bottom edge, which sits at
        // `bottomY` in the entity.
        let bottomY = leaf.origin - shown
        func place(_ part: ModelEntity, from p0: Float, to p1: Float, x: Float, width: Float) {
            let top = min(p1, shown)
            guard top - p0 > 0.002, width > 0.002 else {
                part.isEnabled = false
                return
            }
            part.isEnabled = true
            part.position = SIMD3(x, bottomY + (p0 + top) / 2, 0)
            part.scale = SIMD3(width, top - p0, 1)
        }
        let sideX = w / 2 - border / 2
        place(vinyl.left, from: 0, to: full, x: -sideX, width: border)
        place(vinyl.right, from: 0, to: full, x: sideX, width: border)
        place(vinyl.bottom, from: 0, to: border, x: 0, width: innerW)
        place(vinyl.top, from: full - border, to: full, x: 0, width: innerW)
        // The clear part's ripple texture is placed by panel height, so the
        // ripples travel down with the panel as it unrolls.
        let clearBottom = border + band
        let clearTop = min(full - border, shown)
        place(vinyl.clear, from: clearBottom, to: full - border, x: 0, width: innerW)
        if vinyl.clear.isEnabled {
            let period = Self.ripplePeriod
            let uvOffset = SIMD2<Float>(-innerW / 2 / period, clearTop / period)
            let uvScale = SIMD2<Float>(innerW / period, (clearBottom - clearTop) / period)
            var clear = Self.clearVinylMaterial
            clear.textureCoordinateTransform = .init(offset: uvOffset, scale: uvScale)
            vinyl.clear.model?.materials = [clear]
        }
        if let mesh = vinyl.band {
            place(mesh, from: border, to: border + band, x: 0, width: innerW)
            if mesh.isEnabled {
                let weave = Self.material(for: .insect, color: config.meshColor)
                mesh.model?.materials = [Self.tiled(weave, width: innerW, height: mesh.scale.y)]
            }
        }
    }

    /// `weave` with its texture repeating every `tile` metres over a unit
    /// quad scaled to `width` × `height`.
    private static func tiled(_ weave: UnlitMaterial, width: Float, height: Float) -> UnlitMaterial {
        var material = weave
        let scale = SIMD2<Float>(width / tile, height / tile)
        material.textureCoordinateTransform = .init(offset: .zero, scale: scale)
        return material
    }

    private func addShadow(to entity: ModelEntity) {
        guard castsShadows else { return }
        if #available(iOS 18.0, *) {
            entity.components.set(GroundingShadowComponent(castsShadow: true))
        }
    }

    // MARK: - Meshes

    private static var boxMeshes: [SIMD3<Float>: MeshResource] = [:]

    /// Box meshes are reused for identical sizes (sizes rounded to 0.1 mm).
    private static func boxMesh(_ size: SIMD3<Float>) -> MeshResource {
        let key = (size * 10_000).rounded(.toNearestOrAwayFromZero) / 10_000
        if let cached = boxMeshes[key] { return cached }
        if boxMeshes.count > 200 { boxMeshes.removeAll() }
        let mesh = MeshResource.generateBox(size: key, cornerRadius: 0.002)
        boxMeshes[key] = mesh
        return mesh
    }

    private static var housingMeshes: [String: MeshResource] = [:]

    /// Door housing or motorized headbox: flat back, straight sides and
    /// angled front corners (the extrusion profile), upright or lying across.
    static func chamferedMesh(length: Float, width: Float, depth: Float, chamfer: Float, vertical: Bool) -> MeshResource {
        let key = String(format: "chamfer-%.4f-%.4f-%.4f-%.4f-%d", length, width, depth, chamfer, vertical ? 1 : 0)
        if let cached = housingMeshes[key] { return cached }
        let w = width / 2
        let d = depth / 2
        let c = chamfer
        // Profile across the extrusion (x for upright, y for lying), and z: back at −z.
        let profile: [SIMD2<Float>] = [[-w, -d], [w, -d], [w, d - c], [w - c, d], [-w + c, d], [-w, d - c]]
        let mesh = extrusion(profile: profile, length: length, vertical: vertical)
        if housingMeshes.count > 50 { housingMeshes.removeAll() }
        housingMeshes[key] = mesh
        return mesh
    }

    /// Window housing: flat back with a rounded front, lying across the top.
    static func windowHousingMesh(length: Float) -> MeshResource {
        let key = String(format: "window-%.4f", length)
        if let cached = housingMeshes[key] { return cached }
        let r = windowHousing / 2
        // Profile in (y, z): back corners at z = −r, straight sides, then a
        // half-round front from (−r, 0) through (0, r) to (r, 0).
        var profile: [SIMD2<Float>] = [[-r, -r]]
        for i in 0...10 {
            let a = -Float.pi / 2 + Float(i) / 10 * Float.pi
            profile.append(SIMD2(r * sin(a), r * cos(a)))
        }
        profile.append([r, -r])
        let mesh = extrusion(profile: profile, length: length, vertical: false)
        if housingMeshes.count > 50 { housingMeshes.removeAll() }
        housingMeshes[key] = mesh
        return mesh
    }

    /// Extrudes a convex profile along y (vertical) or x (horizontal), with
    /// flat-shaded sides and capped ends. UVs run along the length so wood
    /// grain follows the extrusion.
    private static func extrusion(profile: [SIMD2<Float>], length: Float, vertical: Bool) -> MeshResource {
        let half = length / 2
        // Profile (a, b) plus position along the length -> local xyz.
        func point(_ p: SIMD2<Float>, _ along: Float) -> SIMD3<Float> {
            vertical ? SIMD3(p.x, along, p.y) : SIMD3(along, p.x, p.y)
        }
        func direction(_ p: SIMD2<Float>) -> SIMD3<Float> {
            vertical ? SIMD3(p.x, 0, p.y) : SIMD3(0, p.x, p.y)
        }
        let axis: SIMD3<Float> = vertical ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        let n = profile.count
        var perimeter: Float = 0
        for i in 0..<n { perimeter += simd_distance(profile[i], profile[(i + 1) % n]) }
        let centroid = profile.reduce(SIMD2<Float>.zero, +) / Float(n)

        var travelled: Float = 0
        for i in 0..<n {
            let a = profile[i]
            let b = profile[(i + 1) % n]
            let edge = b - a
            var normal2 = SIMD2<Float>(edge.y, -edge.x)
            if dot(normal2, (a + b) / 2 - centroid) < 0 { normal2 = -normal2 }
            let normal = normalize(direction(normal2))
            let u0 = travelled / perimeter
            travelled += simd_length(edge)
            let u1 = travelled / perimeter
            let base = UInt32(positions.count)
            positions += [point(a, -half), point(b, -half), point(b, half), point(a, half)]
            normals += Array(repeating: normal, count: 4)
            uvs += [SIMD2(u0, 0), SIMD2(u1, 0), SIMD2(u1, length * 2), SIMD2(u0, length * 2)]
            // Wind so the face points along `normal`.
            let faceNormal = cross(point(b, -half) - point(a, -half), point(a, half) - point(a, -half))
            if dot(faceNormal, normal) > 0 {
                indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            } else {
                indices += [base, base + 2, base + 1, base, base + 3, base + 2]
            }
        }

        // End caps as triangle fans around the centroid.
        for (sign, along) in [(Float(1), half), (Float(-1), -half)] {
            let normal = axis * sign
            let center = UInt32(positions.count)
            positions.append(point(centroid, along))
            normals.append(normal)
            uvs.append(SIMD2(0.5, 0.5))
            for p in profile {
                positions.append(point(p, along))
                normals.append(normal)
                uvs.append(SIMD2(p.x * 4 + 0.5, p.y * 4 + 0.5))
            }
            for i in 0..<UInt32(n) {
                let a = center + 1 + i
                let b = center + 1 + (i + 1) % UInt32(n)
                let faceNormal = cross(positions[Int(a)] - positions[Int(center)],
                                       positions[Int(b)] - positions[Int(center)])
                indices += dot(faceNormal, normal) > 0 ? [center, a, b] : [center, b, a]
            }
        }

        var descriptor = MeshDescriptor(name: "housing")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? MeshResource.generateBox(size: 0.01)
    }

    /// A unit right triangle in the +x/+y quadrant, double-sided.
    private static let cornerMesh: MeshResource = {
        var descriptor = MeshDescriptor(name: "meshLockCorner")
        let p: [SIMD3<Float>] = [[0, 0, 0], [1, 0, 0], [0, 1, 0]]
        descriptor.positions = MeshBuffers.Positions(p + p)
        descriptor.normals = MeshBuffers.Normals(Array(repeating: SIMD3<Float>(0, 0, 1), count: 3) +
                                                 Array(repeating: SIMD3<Float>(0, 0, -1), count: 3))
        descriptor.primitives = .triangles([0, 1, 2, 3, 5, 4])
        return (try? MeshResource.generate(from: [descriptor])) ?? MeshResource.generatePlane(width: 0.01, height: 0.01)
    }()

    /// A double-sided 1 m square, scaled into place. UVs run 0–1, left to
    /// right and top to bottom; materials scale and offset them with a
    /// texture-coordinate transform.
    private static let unitQuad: MeshResource = {
        let corners: [SIMD3<Float>] = [[-0.5, -0.5, 0], [0.5, -0.5, 0], [0.5, 0.5, 0], [-0.5, 0.5, 0]]
        let uvs: [SIMD2<Float>] = [[0, 1], [1, 1], [1, 0], [0, 0]]

        var descriptor = MeshDescriptor(name: "unitQuad")
        descriptor.positions = MeshBuffers.Positions(corners + corners)
        descriptor.normals = MeshBuffers.Normals(
            Array(repeating: SIMD3<Float>(0, 0, 1), count: 4) +
            Array(repeating: SIMD3<Float>(0, 0, -1), count: 4)
        )
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs + uvs)
        // Explicit tangents, for the clear vinyl's normal map.
        descriptor.tangents = MeshBuffers.Tangents(Array(repeating: SIMD3<Float>(1, 0, 0), count: 8))
        descriptor.primitives = .triangles([0, 1, 2, 0, 2, 3, 4, 6, 5, 4, 7, 6])
        return (try? MeshResource.generate(from: [descriptor])) ?? MeshResource.generatePlane(width: 1, height: 1)
    }()

    // MARK: - Textures

    private static var materials: [String: UnlitMaterial] = [:]

    private static func material(for type: MeshType, color: MeshColor) -> UnlitMaterial {
        let key = type.rawValue + "-" + color.rawValue
        if let cached = materials[key] { return cached }
        var material = UnlitMaterial(color: color.uiColor.withAlphaComponent(0.6))
        if let texture = weaveTexture(for: type, color: color) {
            material.color = .init(tint: UIColor.white.withAlphaComponent(0.99), texture: .init(texture))
        }
        material.blending = .transparent(opacity: 0.99)
        materials[key] = material
        return material
    }

    /// One tile of weave in the mesh color on a transparent background.
    /// Denser meshes get thicker strands and a tinted fill.
    private static func weaveTexture(for type: MeshType, color: MeshColor) -> TextureResource? {
        let params: (strands: Int, lineWidth: CGFloat, lineAlpha: CGFloat, fillAlpha: CGFloat)
        switch type {
        case .insect: params = (2, 5, 0.82, 0)
        case .pet: params = (2, 10, 0.9, 0.08)
        case .sun: params = (3, 9, 0.88, 0.32)
        case .privacy: params = (4, 10, 0.95, 0.6)
        }
        let size = CGSize(width: 64, height: 64)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.clear(CGRect(origin: .zero, size: size))
            if params.fillAlpha > 0 {
                cg.setFillColor(color.uiColor.withAlphaComponent(params.fillAlpha).cgColor)
                cg.fill(CGRect(origin: .zero, size: size))
            }
            cg.setStrokeColor(color.uiColor.withAlphaComponent(params.lineAlpha).cgColor)
            cg.setLineWidth(params.lineWidth)
            let step = size.width / CGFloat(params.strands)
            for i in 0..<params.strands {
                let p = CGFloat(i) * step + params.lineWidth / 2
                cg.move(to: CGPoint(x: p, y: 0))
                cg.addLine(to: CGPoint(x: p, y: size.height))
                cg.move(to: CGPoint(x: 0, y: p))
                cg.addLine(to: CGPoint(x: size.width, y: p))
            }
            cg.strokePath()
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource.generate(from: cgImage, options: .init(semantic: .color))
    }

    /// Procedural oak-like grain: warm base with long, slightly wavy streaks.
    private static let woodTexture: TextureResource? = {
        let size = CGSize(width: 128, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> CGFloat {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return CGFloat(seed % 10_000) / 10_000
        }
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor(red: 0.66, green: 0.47, blue: 0.29, alpha: 1).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            for _ in 0..<70 {
                let x = random() * size.width
                let dark = 0.25 + random() * 0.35
                cg.setStrokeColor(UIColor(red: 0.36, green: 0.22, blue: 0.11, alpha: dark).cgColor)
                cg.setLineWidth(0.6 + random() * 2.2)
                let wave = 1 + random() * 3
                let phase = random() * 6
                cg.move(to: CGPoint(x: x, y: 0))
                var y: CGFloat = 0
                while y <= size.height {
                    cg.addLine(to: CGPoint(x: x + sin(y / 40 + phase) * wave, y: y))
                    y += 8
                }
                cg.strokePath()
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        return try? TextureResource.generate(from: cgImage, options: .init(semantic: .color))
    }()
}
