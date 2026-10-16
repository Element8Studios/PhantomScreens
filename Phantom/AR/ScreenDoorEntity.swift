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
/// +X right, +Y up, +Z toward the room. The opening rectangle is the mesh
/// area; the hardware sits around it, as installed:
/// - Doors: an upright housing (flat back, angled front corners) on the
///   retract side, thin top and bottom tracks with an end clip, and a pull bar
///   with a D-shaped handle. No jamb on the far side; the bar closes against
///   the trim.
/// - Oversized door screens: the same, with a heavier housing and bar; two
///   screens meeting in the middle past 15 ft.
/// - Windows: a round-fronted housing across the top and thin side channels.
/// - Motorized screens: a headbox across the top, side tracks to the floor and
///   a bottom bar that lowers inside the opening.
///
/// The static hardware is rebuilt only when size, product or appearance
/// change. Opening and closing only moves the pull bars and resizes the mesh.
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
    /// Every part painted in the frame finish, so colour changes repaint in place.
    private var painted: [ModelEntity] = []

    // Hardware sizes in metres, from the installed product.
    static let housingWidth: Float = 0.055      // door housing, across the opening
    static let housingDepth: Float = 0.06
    static let housingChamfer: Float = 0.014
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

    /// How far the hardware stands proud of the wall when mounted outside.
    static func mountDepth(for config: ScreenConfig) -> Float {
        switch config.product {
        case .window: return windowHousing
        case .motorized: return headbox
        default: return hardware(for: config).housingDepth
        }
    }
    /// World metres covered by one repeat of the mesh texture.
    private static let tile: Float = 0.025

    private enum HandleStyle { case grip, tab, none }

    /// One travelling screen: its mesh quad, pull bar, handle and mesh-lock corners.
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
    }

    required init() {
        config = ScreenConfig()
        super.init()
        addChild(content)
        content.addChild(staticRoot)
        rebuild()
    }

    convenience init(config: ScreenConfig) {
        self.init()
        update(config)
    }

    func update(_ newConfig: ScreenConfig) {
        let old = config
        config = newConfig
        if Self.shape(of: newConfig) != Self.shape(of: old) {
            rebuild()
            return
        }
        // Colour and mesh changes repaint in place: no rebuild, no flicker.
        if newConfig.finish != old.finish || newConfig.customColorHex != old.customColorHex {
            repaint()
        }
        if newConfig.mesh != old.mesh {
            let material = Self.material(for: newConfig.mesh)
            for leaf in leaves where leaf.screen.model != nil {
                leaf.screen.model?.materials = [material]
            }
        }
        if newConfig.extent != extent {
            setExtent(newConfig.extent)
        }
    }

    /// The parts of a configuration that change geometry.
    private static func shape(of config: ScreenConfig) -> ScreenConfig {
        var c = config
        c.extent = 0
        c.finish = .classicWhite
        c.customColorHex = ""
        c.customMatchedToTrim = false
        c.mesh = .insect
        c.colorUndecided = false
        c.closure = .latching
        c.motorControl = .remote
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

    private static let vinylMaterial: PhysicallyBasedMaterial = {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(white: 0.05, alpha: 1))
        material.roughness = .init(floatLiteral: 0.6)
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
        }
        leaves = []

        // Outside mount brings the hardware forward onto the wall face.
        content.position = SIMD3(0, 0, config.mount == .outside ? Self.mountDepth(for: config) / 2 + 0.01 : 0)

        let frame = frameMaterial()
        let w = config.width
        let h = config.height

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
        case .motorized:
            buildMotorized(w: w, h: h, frame: frame)
        }

        extent = min(max(config.extent, 0), 1)
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
        staticPart(housing, SIMD3(s * (-w / 2 - hw.housingWidth / 2), 0, 0), frame)
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
        staticPart(housing, SIMD3(-w / 2 - hw.housingWidth / 2, 0, 0), frame)
        staticPart(housing, SIMD3(w / 2 + hw.housingWidth / 2, 0, 0), frame)
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
        // Side channels run down past the bottom edge, where the closed bar rests.
        let channelLength = h + bw + 0.01
        let channelY = h / 2 - channelLength / 2
        staticBox(SIMD3(tt, channelLength, td), SIMD3(-w / 2 - tt / 2, channelY, trackZ), frame)
        staticBox(SIMD3(tt, channelLength, td), SIMD3(w / 2 + tt / 2, channelY, trackZ), frame)
        addLeaf(origin: h / 2, direction: -1, travel: h + bw, span: w, horizontal: false,
                bar: SIMD2(bw, Self.barDepth), handle: .tab, frame: frame)
    }

    /// Headbox across the top, side tracks down to the floor, and a bottom
    /// bar that comes to rest on the floor inside the opening.
    private func buildMotorized(w: Float, h: Float, frame: PhysicallyBasedMaterial) {
        let hb = Self.headbox
        let tw = Self.sideTrackWidth
        let tdepth = Self.sideTrackDepth
        let headbox = Self.chamferedMesh(length: w + 2 * tw + 0.02, width: hb, depth: hb,
                                         chamfer: Self.headboxChamfer, vertical: false)
        staticPart(headbox, SIMD3(0, h / 2 + hb / 2, 0), frame)
        let trackZ = -hb / 2 + tdepth / 2
        staticBox(SIMD3(tw, h, tdepth), SIMD3(-w / 2 - tw / 2, 0, trackZ), frame)
        staticBox(SIMD3(tw, h, tdepth), SIMD3(w / 2 + tw / 2, 0, trackZ), frame)
        addLeaf(origin: h / 2, direction: -1, travel: h, span: w, horizontal: false,
                bar: SIMD2(Self.bottomBar, tdepth * 0.8), handle: .none, frame: frame)
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

    private func addLeaf(origin: Float, direction: Float, travel: Float, span: Float, horizontal: Bool,
                         bar barDimensions: SIMD2<Float>, handle style: HandleStyle, frame: PhysicallyBasedMaterial) {
        let bw = barDimensions.x
        let bd = barDimensions.y
        let barSize = horizontal ? SIMD3(bw, span, bd) : SIMD3(span, bw, bd)
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

        // Mesh lock: black vinyl triangles in the mesh corners (doors only).
        var corners: [ModelEntity] = []
        if config.hasMeshLock, horizontal {
            for _ in 0..<4 {
                let corner = ModelEntity(mesh: Self.cornerMesh, materials: [Self.vinylMaterial])
                content.addChild(corner)
                corners.append(corner)
            }
        }

        content.addChild(screen)
        content.addChild(bar)
        content.addChild(handle)
        leaves.append(Leaf(origin: origin, direction: direction, travel: travel, span: span,
                           horizontal: horizontal, barWidth: bw, barDepth: bd,
                           screen: screen, bar: bar, handle: handle, corners: corners))
    }

    // MARK: - Moving parts

    func setExtent(_ value: Float) {
        extent = min(max(value, 0), 1)
        config.extent = extent
        layoutLeaves()
    }

    private func layoutLeaves() {
        let material = Self.material(for: config.mesh)
        tracks = []
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
            if visible, let mesh = Self.screenMesh(width: screenW, height: screenH) {
                if leaf.screen.model == nil {
                    leaf.screen.model = ModelComponent(mesh: mesh, materials: [material])
                } else {
                    leaf.screen.model?.mesh = mesh
                }
                leaf.screen.isEnabled = true
            } else {
                leaf.screen.isEnabled = false
            }

            if leaf.horizontal {
                leaf.screen.position = SIMD3(screenAt, 0, 0)
                leaf.bar.position = SIMD3(barAt, 0, 0)
                leaf.handle.position = SIMD3(barAt, 0, handleZ)
                tracks.append(DragTrack(start: SIMD3(leaf.origin, 0, 0),
                                        end: SIMD3(leaf.origin + leaf.direction * leaf.travel, 0, 0),
                                        bar: SIMD3(barAt, 0, 0)))
            } else {
                leaf.screen.position = SIMD3(0, screenAt, 0)
                leaf.bar.position = SIMD3(0, barAt, 0)
                leaf.handle.position = SIMD3(0, barAt, handleZ)
                tracks.append(DragTrack(start: SIMD3(0, leaf.origin, 0),
                                        end: SIMD3(0, leaf.origin + leaf.direction * leaf.travel, 0),
                                        bar: SIMD3(0, barAt, 0)))
            }

            // Mesh-lock corners follow the four corners of the visible mesh.
            if !leaf.corners.isEmpty {
                let size = min(0.07, min(screenW, screenH) / 3)
                let cx = leaf.horizontal ? screenAt : 0
                let cy = leaf.horizontal ? 0 : screenAt
                let signs: [(Float, Float)] = [(-1, 1), (1, 1), (1, -1), (-1, -1)]
                for (corner, sign) in zip(leaf.corners, signs) {
                    corner.isEnabled = visible && size > 0.01
                    corner.position = SIMD3(cx + sign.0 * screenW / 2, cy + sign.1 * screenH / 2, 0.001)
                    // The unit triangle points into +x/+y; flip it toward the mesh.
                    corner.scale = SIMD3(-sign.0 * size, -sign.1 * size, 1)
                }
            }
        }
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

    /// The standard door housing, upright.
    static func doorHousingMesh(length: Float) -> MeshResource {
        let hw = DoorHardware.standard
        return chamferedMesh(length: length, width: hw.housingWidth, depth: hw.housingDepth,
                             chamfer: hw.chamfer, vertical: true)
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

    /// A double-sided quad whose UVs repeat the weave every `tile` metres,
    /// so the mesh keeps its real-world scale as the screen extends.
    private static func screenMesh(width: Float, height: Float) -> MeshResource? {
        let hw = width / 2
        let hh = height / 2
        let u = width / tile
        let v = height / tile
        let corners: [SIMD3<Float>] = [[-hw, -hh, 0], [hw, -hh, 0], [hw, hh, 0], [-hw, hh, 0]]
        let uvs: [SIMD2<Float>] = [[0, v], [u, v], [u, 0], [0, 0]]

        var descriptor = MeshDescriptor(name: "screen")
        descriptor.positions = MeshBuffers.Positions(corners + corners)
        descriptor.normals = MeshBuffers.Normals(
            Array(repeating: SIMD3<Float>(0, 0, 1), count: 4) +
            Array(repeating: SIMD3<Float>(0, 0, -1), count: 4)
        )
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs + uvs)
        descriptor.primitives = .triangles([0, 1, 2, 0, 2, 3, 4, 6, 5, 4, 7, 6])
        return try? MeshResource.generate(from: [descriptor])
    }

    // MARK: - Textures

    private static var materials: [MeshType: UnlitMaterial] = [:]

    private static func material(for type: MeshType) -> UnlitMaterial {
        if let cached = materials[type] { return cached }
        var material = UnlitMaterial(color: UIColor(white: 0.12, alpha: 0.6))
        if let texture = weaveTexture(for: type) {
            material.color = .init(tint: UIColor.white.withAlphaComponent(0.99), texture: .init(texture))
        }
        material.blending = .transparent(opacity: 0.99)
        materials[type] = material
        return material
    }

    /// One tile of charcoal weave on a transparent background. Denser meshes
    /// get thicker strands and a tinted fill.
    private static func weaveTexture(for type: MeshType) -> TextureResource? {
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
                cg.setFillColor(UIColor(white: 0.08, alpha: params.fillAlpha).cgColor)
                cg.fill(CGRect(origin: .zero, size: size))
            }
            cg.setStrokeColor(UIColor(white: 0.1, alpha: params.lineAlpha).cgColor)
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
