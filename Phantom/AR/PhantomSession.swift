import ARKit
import Combine
import RealityKit
import SwiftUI
import UIKit

/// Owns the ARView and the find -> place -> adjust flow.
@MainActor
final class PhantomSession: NSObject, ObservableObject, ARSessionDelegate {
    enum Stage: Equatable {
        case finding, corners, placed
    }

    let arView: ARView
    /// Fast-changing overlay state, observed only by the overlays.
    let live: LiveState
    let hasLiDAR: Bool

    @Published private(set) var stage: Stage = .finding

    // Automatic detection
    @Published private(set) var detectedOpening: Opening?
    @Published private(set) var isLocked = false
    /// An outline is showing but not locked yet.
    @Published private(set) var hasCandidate = false

    // Manual corners
    @Published private(set) var cornerCount = 0
    @Published private(set) var crosshairOnSurface = false

    // Placed
    @Published var config = ScreenConfig() {
        didSet {
            // Vinyl panels are only made for motorized screens. (Assigning
            // here doesn't re-run didSet, so this comes first.)
            if config.mesh.isVinyl, !config.product.isMotorized { config.mesh = .insect }
            door?.update(config)
            syncSizeFromConfig()
            if config.finish != oldValue.finish || config.customColorHex != oldValue.customColorHex {
                whiteCheckSoon()
            }
        }
    }
    @Published private(set) var scannedSize: SIMD2<Float>?
    @Published private(set) var hasDraggedHandle = false

    // Output
    @Published private(set) var photos: [UIImage] = []
    @Published private(set) var flash = 0
    /// The product suggested for the measured opening (shown as "Suggested").
    @Published private(set) var suggestedProduct: Product?
    // Corner guides

    // Fine-tuning corners after placement
    @Published private(set) var isAdjusting = false
    /// A corner is being dragged straight from the screen (handles show only then).
    @Published private(set) var isDraggingCorner = false
    @Published private(set) var fittedOpening: Opening?

    // Settings, saved between launches
    @Published var autoDetect = PhantomSession.stored("autoDetect", true) {
        didSet { PhantomSession.store(autoDetect, "autoDetect"); if !autoDetect { clearDetection() } }
    }
    @Published var showSurfaces = PhantomSession.stored("showSurfaces", false) {
        didSet { PhantomSession.store(showSurfaces, "showSurfaces"); applyDebugOptions() }
    }
    @Published var showDiagonal = PhantomSession.stored("showDiagonal", true) {
        didSet { PhantomSession.store(showDiagonal, "showDiagonal") }
    }
    @Published var showRectangle = PhantomSession.stored("showRectangle", true) {
        didSet { PhantomSession.store(showRectangle, "showRectangle") }
    }
    @Published var realisticLighting = PhantomSession.stored("realisticLighting", true) {
        didSet { PhantomSession.store(realisticLighting, "realisticLighting"); applyRendering() }
    }
    @Published var occlusion = PhantomSession.stored("occlusion", true) {
        didSet { PhantomSession.store(occlusion, "occlusion"); applyRendering() }
    }
    @Published var keepPlumb = PhantomSession.stored("keepPlumb", true) {
        didSet { PhantomSession.store(keepPlumb, "keepPlumb"); refit() }
    }
    @Published var snapCorners = PhantomSession.stored("snapCorners", true) {
        didSet { PhantomSession.store(snapCorners, "snapCorners") }
    }
    @Published var brightness: Float = Float(UserDefaults.standard.double(forKey: "brightness")) {
        didSet { UserDefaults.standard.set(Double(brightness), forKey: "brightness"); applyExposure() }
    }
    @Published var autoMatchWhite = PhantomSession.stored("autoMatchWhite", true) {
        didSet { PhantomSession.store(autoMatchWhite, "autoMatchWhite") }
    }
    @Published var isMatchingWhite = false
    var matchedExposure: Float = 0
    var colorGain = SIMD3<Float>(repeating: 1)
    var whiteMatchTask: Task<Void, Never>?
    /// A quiet white check running in the background (not shown in the UI).
    var isCheckingWhite = false
    /// The user picked the trim by hand; automatic checks leave it alone.
    var whitePickedByUser = false
    var lastWhiteCheck = Date.distantPast
    /// Seconds between quiet white checks; grows while nothing changes.
    var whiteCheckInterval: TimeInterval = 4
    /// Exposure and colour gain as currently shown. They ease toward the
    /// matched values so corrections never jump.
    private var shownExposure: Float = 0
    private(set) var shownGain = SIMD3<Float>(repeating: 1)
    private var lastAppearanceStep = Date()
    private var ambientLevel: Float = 1
    /// The placed screen fades in once ARKit is tracking its anchor.
    private var revealStart: Date?
    private var placedAt = Date.distantPast
    private(set) var isRevealed = false
    @Published var tapToTarget = PhantomSession.stored("tapToTarget", false) {
        didSet { PhantomSession.store(tapToTarget, "tapToTarget"); clearTarget() }
    }
    var targetPoint: SIMD3<Float>? {
        didSet { if (targetPoint != nil) != hasTarget { hasTarget = targetPoint != nil } }
    }
    @Published private(set) var hasTarget = false
    /// Non-nil while the centre-screen colour picker is showing.
    @Published var pickerPurpose: PickerPurpose?
    var lastPickSample = Date.distantPast
    @Published var sunMode = PhantomSession.stored("sunMode", false) {
        didSet {
            PhantomSession.store(sunMode, "sunMode")
            // Changing the world's alignment restarts tracking.
            if stage != .finding { remeasure() }
            start(reset: true)
        }
    }
    @Published var sunExposure = SunExposure(rawValue: UserDefaults.standard.string(forKey: "sunExposure") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(sunExposure.rawValue, forKey: "sunExposure"); updateLighting(force: true) }
    }
    let locationProvider = LocationProvider()
    var usingSunLight = false
    /// Developer: keep re-checking white every few seconds after the first
    /// match. Off: white is matched once, when the screen appears.
    @Published var keepCheckingWhite = PhantomSession.stored("keepCheckingWhite", false) {
        didSet { PhantomSession.store(keepCheckingWhite, "keepCheckingWhite") }
    }
    /// Shows product options normally decided during installation, like a
    /// motorized headbox recessed into the ceiling.
    @Published var advancedProductOptions = PhantomSession.stored("advancedProductOptions", false) {
        didSet { PhantomSession.store(advancedProductOptions, "advancedProductOptions") }
    }
    /// The bug test is running (see BugTest.swift).
    @Published var bugTestRunning = false
    /// The flying bugs while the bug test runs.
    var bugTest: BugTest?
    /// Developer: frame rate, detection method and wall plane on screen.
    @Published var showDebug = PhantomSession.stored("showDebug", false) {
        didSet { PhantomSession.store(showDebug, "showDebug") }
    }
    /// Developer: stop LiDAR depth once a screen is placed, to save battery.
    /// Off by default until tested on more phones (re-running ARKit's
    /// configuration can cause a brief tracking hitch).
    @Published var depthOffWhenPlaced = PhantomSession.stored("depthOffWhenPlaced", false) {
        didSet { PhantomSession.store(depthOffWhenPlaced, "depthOffWhenPlaced") }
    }
    @Published var gloss = PaintGloss(rawValue: UserDefaults.standard.string(forKey: "gloss") ?? "") ?? .gloss {
        didSet { UserDefaults.standard.set(gloss.rawValue, forKey: "gloss"); applyRendering() }
    }


    private static func stored(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    private static func store(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    var door: ScreenDoorEntity?
    private var doorAnchor: AnchorEntity?
    private var keyLight: DirectionalLight?
    private var lastLightUpdate = Date.distantPast
    private var lastLevelUpdate = Date()
    private var lastCornerTick = Date.distantPast
    private var lastRecovery = Date.distantPast
    private var lastOverlayTick = Date.distantPast

    /// True while a sheet or menu covers the camera view. Pauses overlay
    /// updates and the costlier camera effects so the menu stays smooth.
    var menuOpen = false {
        didSet {
            guard menuOpen != oldValue else { return }
            let effects: ARView.RenderOptions = [.disableDepthOfField, .disableMotionBlur]
            if menuOpen { arView.renderOptions.formUnion(effects) } else { arView.renderOptions.subtract(effects) }
            // Style changes made behind the sheet get checked once it closes.
            if !menuOpen { whiteCheckSoon() }
        }
    }
    private var adjustIndex: Int?
    private var touchMode: TouchMode = .none
    /// The fitted opening's space; the door and bug test live in it.
    private(set) var frameEntity: Entity?
    private var cornerPoints: [SIMD3<Float>] = []
    private var scannedCorners: [SIMD3<Float>] = []
    private var isRefitting = false
    private var openingAnchor: ARAnchor?
    private var markers: [AnchorEntity] = []
    private var firstCorner: SIMD3<Float> = .zero
    private var firstNormal: SIMD3<Float> = SIMD3(0, 0, 1)
    private var updateSubscription: Cancellable?
    private var lastDetection = Date.distantPast
    private var isDetecting = false
    private var stableCount = 0
    private var dragTrackIndex: Int?
    private var animation: Task<Void, Never>?
    private var toastToken = 0
    private let visionQueue = DispatchQueue(label: "phantom.vision", qos: .userInitiated)

    override init() {
        arView = ARView(frame: .zero)
        live = LiveState()
        hasLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        super.init()

        arView.automaticallyConfigureSession = false
        arView.session.delegate = self
        applyRendering()
        applyDebugOptions()

        let coaching = ARCoachingOverlayView()
        coaching.session = arView.session
        coaching.goal = .verticalPlane
        coaching.activatesAutomatically = true
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(coaching)

        updateSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFrame() }
        }
    }

    // MARK: - Session

    func start(reset: Bool = false) {
        guard ARWorldTrackingConfiguration.isSupported else {
            showToast("This iPhone doesn't support AR.", duration: 10)
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        // Sun mode needs true north to point the sun; this uses the compass.
        configuration.worldAlignment = sunMode ? .gravityAndHeading : .gravity
        if sunMode { locationProvider.request() }
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        if hasLiDAR {
            // Labels door and window surfaces, which finds closed doors.
            configuration.sceneReconstruction =
                ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
                ? .meshWithClassification : .mesh
        }
        // One depth stream is enough; smoothed depth is steadier for edges.
        // Depth is only needed while measuring (see depthOffWhenPlaced).
        let wantsDepth = !(depthOffWhenPlaced && stage == .placed)
        if wantsDepth, ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if wantsDepth, ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        configuration.wantsHDREnvironmentTextures = true
        configuration.isLightEstimationEnabled = true
        arView.session.run(configuration, options: reset ? [.resetTracking, .removeExistingAnchors] : [])
    }

    // MARK: - Rendering

    private func applyDebugOptions() {
        if showSurfaces {
            arView.debugOptions = hasLiDAR ? [.showSceneUnderstanding] : [.showAnchorGeometry, .showFeaturePoints]
        } else {
            arView.debugOptions = []
        }
    }

    private func applyRendering() {
        var options = arView.environment.sceneUnderstanding.options
        if hasLiDAR && occlusion { options.insert(.occlusion) } else { options.remove(.occlusion) }
        // Lets the real-world mesh receive shadows from the screen.
        if hasLiDAR && realisticLighting { options.insert(.receivesLighting) } else { options.remove(.receivesLighting) }
        arView.environment.sceneUnderstanding.options = options
        keyLight?.isEnabled = realisticLighting
        door?.setAppearance(gloss: gloss, castsShadows: realisticLighting, colorGain: shownGain)
    }

    /// Follows ARKit's estimate of the room's brightness. The light stays
    /// neutral: the camera image is already white-balanced, so tinting the
    /// light by the room's colour temperature would push whites off-white.
    func updateLighting(force: Bool = false) {
        guard realisticLighting, let light = keyLight,
              force || Date().timeIntervalSince(lastLightUpdate) > 0.4 else { return }
        lastLightUpdate = Date()
        if let estimate = arView.session.currentFrame?.lightEstimate {
            // Eased over about a second, so the estimate's jitter doesn't flicker.
            let target = min(max(Float(estimate.ambientIntensity) / 1000, 0.5), 1.5)
            let elapsed = Float(min(Date().timeIntervalSince(lastLevelUpdate), 1))
            lastLevelUpdate = Date()
            ambientLevel += (target - ambientLevel) * elapsed
        }
        let level = ambientLevel
        if updateSunLight(light, level: level) {
            usingSunLight = true
            return
        }
        if usingSunLight, let parent = light.parent {
            // Back to the soft indoor key light above and in front.
            light.look(at: .zero, from: SIMD3(0.6, 2.4, 1.8), relativeTo: parent)
            light.shadow = DirectionalLightComponent.Shadow(maximumDistance: 5, depthBias: 3)
            usingSunLight = false
        }
        light.light.color = .white
        light.light.intensity = 900 * level * pow(2, shownExposure)
    }

    /// Virtual exposure: the matched offset plus the user's brightness setting.
    var exposureOffset: Float { matchedExposure + brightness }

    /// The exposure eases to its new value in `stepAppearance`.
    func applyExposure() {
        lastAppearanceStep = Date()
    }

    /// Eases the shown exposure and colour gain toward their targets.
    private func stepAppearance() {
        let now = Date()
        let k = min(1, Float(now.timeIntervalSince(lastAppearanceStep)) * 6)
        lastAppearanceStep = now
        let exposure = exposureOffset
        if abs(shownExposure - exposure) > 0.001 {
            shownExposure += (exposure - shownExposure) * k
            if abs(shownExposure - exposure) < 0.004 { shownExposure = exposure }
            arView.environment.lighting.intensityExponent = shownExposure
            updateLighting(force: true)
        }
        if simd_length(shownGain - colorGain) > 0.001 {
            shownGain += (colorGain - shownGain) * k
            if simd_length(shownGain - colorGain) < 0.004 { shownGain = colorGain }
            door?.setAppearance(gloss: gloss, castsShadows: realisticLighting, colorGain: shownGain)
        }
    }

    var appearanceSettled: Bool {
        abs(shownExposure - exposureOffset) < 0.01 && simd_length(shownGain - colorGain) < 0.01
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let text: String?
        switch camera.trackingState {
        case .normal: text = nil
        case .notAvailable: text = "Tracking unavailable"
        case .limited(.excessiveMotion): text = "Slow down a little"
        case .limited(.insufficientFeatures): text = "Aim at a more detailed area"
        case .limited(.initializing): text = "Getting ready…"
        case .limited(.relocalizing): text = "Finding your place…"
        @unknown default: text = "Tracking limited"
        }
        Task { @MainActor [weak self] in
            guard let self, self.live.status.trackingMessage != text else { return }
            self.live.status.trackingMessage = text
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let code = (error as? ARError)?.code
        Task { @MainActor [weak self] in self?.recover(from: code) }
    }

    /// A failed ARSession stops delivering frames and the camera freezes, so
    /// restart it rather than leaving the app stuck.
    private func recover(from code: ARError.Code?) {
        guard Date().timeIntervalSince(lastRecovery) > 2 else { return }
        lastRecovery = Date()
        if code == .sensorFailed, sunMode {
            // Heading-aligned tracking needs the compass; fall back without it.
            showToast("The compass isn't available here, so outdoor sun shadows were turned off.", duration: 5)
            sunMode = false   // restarts the session
            return
        }
        showToast("AR stopped unexpectedly. Restarting…", duration: 3)
        isDetecting = false
        if stage != .finding { remeasure() }
        clearDetection()
        start(reset: true)
    }

    private var frameCount = 0
    private var frameCountStart = Date()

    private func onFrame() {
        if showDebug {
            frameCount += 1
            let elapsed = Date().timeIntervalSince(frameCountStart)
            if elapsed >= 0.5 {
                live.debug.fps = Int((Double(frameCount) / elapsed).rounded())
                let outdoors = isOutdoors
                if live.debug.outdoors != outdoors { live.debug.outdoors = outdoors }
                frameCount = 0
                frameCountStart = Date()
            }
        }
        switch stage {
        case .finding:
            runDetectionIfDue()
        case .corners:
            // Two raycasts per tick; 30 per second is plenty for the crosshair.
            guard Date().timeIntervalSince(lastCornerTick) > 1.0 / 30 else { return }
            lastCornerTick = Date()
            let hit = centerRaycast()
            if (hit != nil) != crosshairOnSurface { crosshairOnSurface = hit != nil }
            updateCornerPreview(hit)
        case .placed:
            stepBugs()
            stepReveal()
            stepAppearance()
            updateLighting()
            updatePickedColor()
            checkWhiteIfDue()
            // Overlays aren't visible behind a menu or the colour picker, and
            // 30 updates a second is plenty for dots and hints.
            guard !menuOpen, pickerPurpose == nil || isAdjusting,
                  Date().timeIntervalSince(lastOverlayTick) > 1.0 / 30 else { return }
            lastOverlayTick = Date()
            updateHandleHint()
            updateAdjustHandles()
        }
    }

    // MARK: - Automatic detection

    var detectionPrompt: String {
        hasLiDAR ? "Aim at the middle of a doorway or window" : "Point at a doorway or window"
    }

    var openingKind: String {
        guard let opening = detectedOpening else { return "Opening" }
        switch suggestion(for: opening) {
        case .window: return "Window"
        case .motorized: return "Outdoor opening"
        case .oversized: return "Large doorway"
        default: return "Doorway"
        }
    }

    /// Inside the jamb when there's room for the housing in front of what
    /// fills the opening (an open doorway, or a door set well back); on the
    /// face of the trim when a closed door sits nearly flush with it.
    /// Motorized screens mount on the face of posts and beams.
    func suggestedMount(for opening: Opening, product: Product) -> Mount {
        if product == .motorized { return .outside }
        guard hasLiDAR, let frame = arView.session.currentFrame,
              let screen = arView.project(opening.center), arView.bounds.contains(screen),
              let depth = depth(at: screen, in: frame),
              let point = unproject(screen, depth: depth) else { return .inside }
        // How far behind the opening's face the surface in it is.
        let recess = -dot(point - opening.center, opening.normal)
        if recess > 0.3 { return .inside }   // open: the room or yard beyond
        var withProduct = config
        withProduct.product = product
        let room = ScreenDoorEntity.mountDepth(for: withProduct) + 0.02
        return recess >= room ? .inside : .outside
    }

    /// The product that fits a measured opening, using the floor (for a
    /// window sill) and whether the camera's exposure says it's outdoors.
    func suggestion(for opening: Opening) -> Product {
        let frame = arView.session.currentFrame
        let bottom = opening.center.y - opening.height / 2
        let sill = frame.flatMap { floorHeight($0) }.map { bottom - $0 }
        return Product.suggested(width: opening.width, height: opening.height, sill: sill, outdoors: isOutdoors)
    }

    private func runDetectionIfDue() {
        guard autoDetect, !isDetecting,
              Date().timeIntervalSince(lastDetection) > 0.3,
              let frame = arView.session.currentFrame,
              case .normal = frame.camera.trackingState else { return }

        // Where to look: the tapped target, or (unless waiting for a tap) the
        // middle of the screen.
        let start: CGPoint
        if let target = targetPoint, let projected = arView.project(target), arView.bounds.contains(projected) {
            if live.detection.target.map({ hypot($0.x - projected.x, $0.y - projected.y) > 2 }) ?? true {
                live.detection.target = projected
            }
            start = projected
        } else {
            if live.detection.target != nil { live.detection.target = nil }
            guard !tapToTarget else { return }
            start = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        }
        lastDetection = Date()
        isDetecting = true
        let camera = CameraModel(frame: frame, viewSize: arView.bounds.size)

        // LiDAR: the opening is a region much deeper than the wall around it.
        // All the work happens off the main thread, so the camera keeps flowing.
        if hasLiDAR {
            guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else {
                isDetecting = false
                return
            }
            let position = camera.position
            var walls: [WallCandidate] = []
            var meshes: [ARMeshAnchor] = []
            for anchor in frame.anchors {
                if let plane = anchor as? ARPlaneAnchor {
                    if let wall = WallCandidate(plane, cameraPosition: position) { walls.append(wall) }
                } else if let mesh = anchor as? ARMeshAnchor,
                          simd_distance(mesh.transform.translation, position) < 6 {
                    meshes.append(mesh)
                }
            }
            let input = DepthOpeningDetector.Input(depth: depth, camera: camera, start: start,
                                                   floorY: floorHeight(frame), walls: walls, meshes: meshes,
                                                   image: frame.capturedImage)
            visionQueue.async { [weak self] in
                let found = DepthOpeningDetector.detect(input)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isDetecting = false
                    guard self.stage == .finding, self.autoDetect else { return }
                    if self.showDebug {
                        self.live.debug.method = found?.method ?? "none"
                        self.live.debug.wall = found?.usedWall ?? false
                    }
                    if let found {
                        // Re-project with the current camera: the phone moved a little meanwhile.
                        let quad = found.opening.corners.compactMap { self.arView.project($0) }
                        self.accept(found.opening, quad: quad.count == 4 ? quad : found.quad)
                    } else {
                        self.loseDetection()
                    }
                }
            }
            return
        }

        // No LiDAR: look for the frame's outline in the image.
        let buffer = frame.capturedImage
        let viewSize = arView.bounds.size
        let transform = camera.toView

        visionQueue.async { [weak self] in
            let candidates = OpeningDetector.detect(in: buffer).map { quad in
                quad.map { point -> CGPoint in
                    let normalized = point.applying(transform)
                    return CGPoint(x: normalized.x * viewSize.width, y: normalized.y * viewSize.height)
                }
            }
            Task { @MainActor [weak self] in
                self?.isDetecting = false
                self?.handleCandidates(candidates, around: start)
            }
        }
    }

    /// Vision candidates: keep the ones around the target point, then pick the
    /// nearest opening to the camera.
    private func handleCandidates(_ candidates: [[CGPoint]], around point: CGPoint) {
        guard stage == .finding, autoDetect else { return }
        let camera = arView.cameraTransform.translation
        var best: (opening: Opening, quad: [CGPoint], distance: Float)?
        for points in candidates.prefix(4) where points.count == 4 {
            let quad = DepthOpeningDetector.ordered(points)
            if targetPoint != nil, !DepthOpeningDetector.contains(quad, point) { continue }
            guard let opening = reconstruct(quad) else { continue }
            let distance = simd_distance(opening.center, camera)
            if distance < (best?.distance ?? .infinity) { best = (opening, quad, distance) }
        }
        if let best {
            accept(best.opening, quad: best.quad)
        } else {
            loseDetection()
        }
    }

    // MARK: - Tap to target

    /// Sets the opening to look for from a tap. Taps on the frame or wall are
    /// moved to the deepest nearby point, which is inside the opening.
    func setTarget(at point: CGPoint) {
        guard let frame = arView.session.currentFrame else { return }
        var chosen = point
        var chosenDepth = depth(at: point, in: frame)
        if hasLiDAR, let tapped = chosenDepth {
            var deepest = tapped
            for radius in stride(from: CGFloat(40), through: 200, by: 40) {
                for angle in stride(from: 0.0, to: 2 * Double.pi, by: Double.pi / 4) {
                    let p = CGPoint(x: point.x + radius * CGFloat(cos(angle)), y: point.y + radius * CGFloat(sin(angle)))
                    guard arView.bounds.contains(p), let d = depth(at: p, in: frame) else { continue }
                    if d > deepest + 0.4 { deepest = d; chosen = p }
                }
                if deepest > tapped + 0.4 { break }
            }
            chosenDepth = deepest
        }
        if let d = chosenDepth, let world = unproject(chosen, depth: d) {
            targetPoint = world
        } else if let hit = arView.raycast(from: chosen, allowing: .estimatedPlane, alignment: .any).first {
            targetPoint = hit.worldTransform.translation
        } else {
            showToast("Couldn't find that spot. Try tapping inside the opening.")
            return
        }
        live.detection.target = chosen
        clearDetection()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func clearTarget() {
        targetPoint = nil
        live.detection.target = nil
        clearDetection()
    }

    private func accept(_ opening: Opening, quad: [CGPoint]) {
        if let previous = detectedOpening,
           abs(previous.width - opening.width) < 0.04,
           abs(previous.height - opening.height) < 0.04 {
            stableCount = min(stableCount + 1, 8)
        } else {
            stableCount = 1
        }
        live.detection.quad = quad
        if !hasCandidate { hasCandidate = true }
        detectedOpening = opening

        let locked = stableCount >= 3
        if locked && !isLocked {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        isLocked = locked
    }

    private func loseDetection() {
        stableCount = max(stableCount - 1, 0)
        if stableCount == 0 {
            live.detection.quad = []
            hasCandidate = false
            detectedOpening = nil
            isLocked = false
        }
    }

    /// Turns a screen-space quad into a measured opening on the wall.
    private func reconstruct(_ quad: [CGPoint]) -> Opening? {
        let centroid = CGPoint(x: quad.map(\.x).reduce(0, +) / 4, y: quad.map(\.y).reduce(0, +) / 4)

        // Probe just outside each corner so the ray lands on the wall or
        // trim around the opening rather than through it.
        var hitPoints: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        for corner in quad {
            let dx = corner.x - centroid.x
            let dy = corner.y - centroid.y
            let len = max(hypot(dx, dy), 1)
            let probe = CGPoint(x: corner.x + dx / len * 14, y: corner.y + dy / len * 14)
            if let hit = arView.raycast(from: probe, allowing: .estimatedPlane, alignment: .any).first {
                hitPoints.append(hit.worldTransform.translation)
                normals.append(hit.worldTransform.yAxis)
            }
        }
        guard hitPoints.count >= 2 else { return nil }

        let normalSum = normals.reduce(SIMD3<Float>.zero, +)
        guard length(normalSum) > 1e-3 else { return nil }
        let normal = normalize(normalSum)
        guard abs(normal.y) < 0.6 else { return nil } // walls only
        let planePoint = hitPoints.reduce(SIMD3<Float>.zero, +) / Float(hitPoints.count)

        // Intersect the exact corner rays with the wall plane.
        var corners: [SIMD3<Float>] = []
        for corner in quad {
            guard let ray = arView.ray(through: corner) else { return nil }
            let denom = dot(ray.direction, normal)
            guard abs(denom) > 1e-4 else { return nil }
            let t = dot(planePoint - ray.origin, normal) / denom
            guard t > 0 else { return nil }
            corners.append(ray.origin + ray.direction * t)
        }

        guard var opening = Opening.make(
            cornerA: corners[0],
            cornerB: corners[2],
            surfaceNormal: normal,
            cameraPosition: arView.cameraTransform.translation
        ) else { return nil }

        // Average opposite edges for a steadier size.
        let r = opening.right
        let u = opening.up
        opening.width = (abs(dot(corners[1] - corners[0], r)) + abs(dot(corners[2] - corners[3], r))) / 2
        opening.height = (abs(dot(corners[3] - corners[0], u)) + abs(dot(corners[2] - corners[1], u))) / 2
        var center = corners.reduce(SIMD3<Float>.zero, +) / 4
        center -= dot(center - planePoint, opening.normal) * opening.normal
        opening.center = center

        guard ScreenConfig.widthRange.contains(opening.width),
              ScreenConfig.heightRange.contains(opening.height) else { return nil }
        return opening
    }

    func placeDetected() {
        guard isLocked, let opening = detectedOpening else { return }
        place(opening)
    }

    // MARK: - Manual corners

    func startCorners() {
        clearDetection()
        clearMarkers()
        cornerCount = 0
        live.corners.preview = nil
        stage = .corners
    }

    func backToAuto() {
        clearMarkers()
        cornerCount = 0
        live.corners.preview = nil
        stage = .finding
    }

    func undoCorner() {
        guard cornerCount > 0 else { return }
        markers.popLast()?.removeFromParent()
        cornerCount -= 1
        live.corners.preview = nil
    }

    /// Live diagonal and rectangle from the first corner to the crosshair.
    private func updateCornerPreview(_ hit: ARRaycastResult?) {
        guard cornerCount == 1, let hit else {
            if live.corners.preview != nil { live.corners.preview = nil }
            return
        }
        let end = hit.worldTransform.translation
        guard let start2D = arView.project(firstCorner),
              let end2D = arView.project(end) else { return }
        var quad: [CGPoint] = []
        var width: Float = 0
        var height: Float = 0
        if let opening = Opening.make(cornerA: firstCorner, cornerB: end, surfaceNormal: firstNormal,
                                      cameraPosition: arView.cameraTransform.translation) {
            quad = opening.corners.compactMap { arView.project($0) }
            if quad.count != 4 { quad = [] }
            width = opening.width
            height = opening.height
        }
        live.corners.preview = CornerPreview(start: start2D, end: end2D, quad: quad, width: width, height: height)
    }

    private func centerRaycast() -> ARRaycastResult? {
        let point = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        if let hit = arView.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .any).first {
            return hit
        }
        return arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first
    }

    func addCorner() {
        guard stage == .corners else { return }
        guard let hit = centerRaycast() else {
            showToast("No surface under the dot. Move closer or scan a little more.")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        let point = hit.worldTransform.translation
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        addMarker(at: point)

        if cornerCount == 0 {
            firstCorner = point
            firstNormal = hit.worldTransform.yAxis
            cornerCount = 1
            return
        }

        guard let opening = Opening.make(
            cornerA: firstCorner,
            cornerB: point,
            surfaceNormal: firstNormal,
            cameraPosition: arView.cameraTransform.translation
        ) else {
            showToast("Those corners are too close together. Try again.")
            clearMarkers()
            cornerCount = 0
            live.corners.preview = nil
            return
        }
        live.corners.preview = nil
        place(opening)
        showToast("Touch a corner of the screen and drag it to fine-tune the fit.", duration: 4)
    }

    private func addMarker(at position: SIMD3<Float>) {
        let sphere = ModelEntity(mesh: .generateSphere(radius: 0.012),
                                 materials: [UnlitMaterial(color: UIColor(Color.phantomGuide))])
        let anchor = AnchorEntity(world: position)
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        markers.append(anchor)
    }

    private func clearMarkers() {
        markers.forEach { $0.removeFromParent() }
        markers.removeAll()
    }

    private func clearDetection() {
        live.detection.quad = []
        hasCandidate = false
        detectedOpening = nil
        isLocked = false
        stableCount = 0
    }

    // MARK: - Placement

    private func place(_ opening: Opening) {
        removeDoor()
        clearMarkers()
        clearDetection()

        let arAnchor = ARAnchor(name: "phantom.opening", transform: opening.transform)
        arView.session.add(anchor: arAnchor)
        openingAnchor = arAnchor

        var newConfig = config
        newConfig.width = min(max(opening.width, ScreenConfig.widthRange.lowerBound), ScreenConfig.widthRange.upperBound)
        newConfig.height = min(max(opening.height, ScreenConfig.heightRange.lowerBound), ScreenConfig.heightRange.upperBound)
        let suggested = suggestion(for: opening)
        newConfig.product = suggested
        newConfig.mount = suggestedMount(for: opening, product: suggested)
        suggestedProduct = suggested
        newConfig.extent = 0
        isRefitting = true
        config = newConfig
        isRefitting = false
        live.screen.extent = 0
        live.detection.target = nil

        // anchor (tracked by ARKit) -> frame (the fitted opening) -> door + light
        let anchorEntity = AnchorEntity(.anchor(identifier: arAnchor.identifier))
        let frame = Entity()
        anchorEntity.addChild(frame)

        let door = ScreenDoorEntity(config: config)
        door.setAppearance(gloss: gloss, castsShadows: realisticLighting, colorGain: shownGain)
        frame.addChild(door)
        // Hidden until ARKit tracks the anchor, then faded in (see stepReveal).
        frame.isEnabled = false

        // Soft key light from above and in front, casting shadows on the wall.
        let light = DirectionalLight()
        light.light.intensity = 900
        light.shadow = DirectionalLightComponent.Shadow(maximumDistance: 5, depthBias: 3)
        frame.addChild(light)
        light.look(at: .zero, from: SIMD3(0.6, 2.4, 1.8), relativeTo: frame)
        light.isEnabled = realisticLighting
        keyLight = light
        lastLightUpdate = .distantPast

        arView.scene.addAnchor(anchorEntity)
        self.door = door
        doorAnchor = anchorEntity
        frameEntity = frame
        isAdjusting = false

        cornerPoints = opening.corners
        refit()
        refitWall(announce: false)
        scannedCorners = cornerPoints
        if let fitted = fittedOpening { scannedSize = SIMD2(fitted.width, fitted.height) }

        stage = .placed
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        whitePickedByUser = false
        placedAt = Date()
        revealStart = nil
        isRevealed = false
        applyExposure()
    }

    /// Shows the new screen once its anchor is tracked (or after a moment),
    /// fading it in while it slides partly open, then matches the white.
    private func stepReveal() {
        guard !isRevealed, let frame = frameEntity else { return }
        guard let began = revealStart else {
            let anchored = doorAnchor?.isAnchored ?? false
            guard anchored || Date().timeIntervalSince(placedAt) > 1 else { return }
            revealStart = Date()
            frame.isEnabled = true
            if #available(iOS 18.0, *) {
                frame.components.set(OpacityComponent(opacity: 0))
            }
            animate(to: 0.65)
            return
        }
        let t = Float(min(Date().timeIntervalSince(began) / 0.45, 1))
        if #available(iOS 18.0, *) {
            frame.components.set(OpacityComponent(opacity: t * t * (3 - 2 * t)))
        }
        guard t >= 1 else { return }
        if #available(iOS 18.0, *) {
            frame.components.remove(OpacityComponent.self)
        }
        isRevealed = true
        if autoMatchWhite { matchWhiteToTrim(announce: false, delay: 0.2) }
    }

    private func removeDoor() {
        animation?.cancel()
        whiteMatchTask?.cancel()
        isMatchingWhite = false
        isCheckingWhite = false
        stopBugTest()
        doorAnchor?.removeFromParent()
        doorAnchor = nil
        frameEntity = nil
        door = nil
        keyLight = nil
        live.hint.point = nil
        isAdjusting = false
        isDraggingCorner = false
        isRevealed = false
        revealStart = nil
        live.corners.handles = []
        live.corners.outline = []
        cornerPoints = []
        fittedOpening = nil
        if let anchor = openingAnchor {
            arView.session.remove(anchor: anchor)
            openingAnchor = nil
        }
    }

    /// Clears the door and goes back to looking for an opening.
    func remeasure() {
        clearTarget()
        removeDoor()
        clearMarkers()
        cornerCount = 0
        stage = .finding
    }

    func resetFitToScan() {
        guard scannedCorners.count == 4 else { return }
        cornerPoints = scannedCorners
        refit()
    }

    // MARK: - Fitting the opening to its corners

    /// Re-fits the screen's rectangle to the four corner points and moves it there.
    private func refit() {
        guard cornerPoints.count == 4, let frame = frameEntity,
              let opening = Opening.fit(corners: cornerPoints, plumb: keepPlumb,
                                        cameraPosition: arView.cameraTransform.translation) else { return }
        fittedOpening = opening
        // Position relative to the ARAnchor's own transform. The AnchorEntity
        // isn't tracked until the next frame, so its current world transform
        // can't be trusted right after placement.
        if let anchor = openingAnchor {
            frame.transform = Transform(matrix: anchor.transform.inverse * opening.transform)
        } else {
            frame.setTransformMatrix(opening.transform, relativeTo: nil)
        }
        var newConfig = config
        newConfig.width = min(max(opening.width, ScreenConfig.widthRange.lowerBound), ScreenConfig.widthRange.upperBound)
        newConfig.height = min(max(opening.height, ScreenConfig.heightRange.lowerBound), ScreenConfig.heightRange.upperBound)
        if newConfig != config {
            isRefitting = true
            config = newConfig
            isRefitting = false
        }
    }

    /// Width or height changed from the Fit sheet: resize around the centre.
    private func syncSizeFromConfig() {
        guard !isRefitting, var opening = fittedOpening,
              abs(config.width - opening.width) > 0.0005 || abs(config.height - opening.height) > 0.0005 else { return }
        opening.width = config.width
        opening.height = config.height
        cornerPoints = opening.corners
        refit()
    }

    /// Samples the wall around the opening and re-fits the plane. Prefers
    /// ARKit's own vertical plane when one lines up, since it keeps refining.
    @discardableResult
    func refitWall(announce: Bool = true) -> Bool {
        guard let opening = fittedOpening, let frame = arView.session.currentFrame else { return false }

        var normal: SIMD3<Float>?
        var planePoint: SIMD3<Float>?

        for case let plane as ARPlaneAnchor in frame.anchors where plane.alignment == .vertical {
            var n = plane.transform.yAxis
            if dot(n, opening.normal) < 0 { n = -n }
            let p = plane.transform.translation
            let distance = abs(dot(opening.center - p, n))
            if dot(n, opening.normal) > cos(Float.pi / 12), distance < 0.15 {
                normal = n
                planePoint = p
                break
            }
        }

        var hits = 0
        if normal == nil {
            var normals: [SIMD3<Float>] = []
            var offsets: [Float] = []
            let r = opening.right
            let u = opening.up
            let hw = opening.width / 2 + 0.08
            let hh = opening.height / 2 + 0.08
            var samples: [SIMD3<Float>] = []
            for t in stride(from: Float(-0.9), through: 0.9, by: 0.3) {
                samples.append(opening.center + u * hh + r * (t * opening.width / 2)) // above
                samples.append(opening.center - r * hw + u * (t * opening.height / 2)) // left
                samples.append(opening.center + r * hw + u * (t * opening.height / 2)) // right
            }
            let bounds = arView.bounds
            for sample in samples {
                guard let screen = arView.project(sample), bounds.contains(screen),
                      let hit = arView.raycast(from: screen, allowing: .estimatedPlane, alignment: .any).first
                else { continue }
                var n = hit.worldTransform.yAxis
                if dot(n, opening.normal) < 0 { n = -n }
                let offset = dot(hit.worldTransform.translation - opening.center, opening.normal)
                guard dot(n, opening.normal) > cos(Float.pi / 7), abs(offset) < 0.25 else { continue }
                normals.append(n)
                offsets.append(offset)
            }
            hits = normals.count
            guard hits >= 4 else {
                if announce { showToast("Couldn't see enough wall. Step back so the wall around the opening is on screen.", duration: 4) }
                return false
            }
            normal = normalize(normals.reduce(SIMD3<Float>.zero, +))
            planePoint = opening.center + opening.normal * DepthEdge.median(offsets)
        }

        guard var n = normal, let p = planePoint else { return false }
        if keepPlumb {
            n.y = 0
            guard length(n) > 1e-3 else { return false }
            n = normalize(n)
        }
        cornerPoints = cornerPoints.map { $0 - dot($0 - p, n) * n }
        refit()
        if announce {
            showToast(hits > 0 ? "Wall re-fitted from \(hits) points." : "Wall re-fitted to the detected wall plane.")
        }
        return true
    }

    enum AlignmentAxis { case turn, tilt, twist }

    /// Rotates the screen about its centre in half-degree steps.
    func rotate(_ axis: AlignmentAxis, degrees: Float) {
        guard let o = fittedOpening else { return }
        let vector: SIMD3<Float>
        switch axis {
        case .turn: vector = SIMD3(0, 1, 0)
        case .tilt: vector = o.right
        case .twist: vector = o.normal
        }
        let rotation = simd_quatf(angle: degrees * .pi / 180, axis: vector)
        cornerPoints = cornerPoints.map { o.center + rotation.act($0 - o.center) }
        refit()
    }

    /// Moves the screen toward (+) or away from (−) the room.
    func moveDepth(_ metres: Float) {
        guard let o = fittedOpening else { return }
        cornerPoints = cornerPoints.map { $0 + o.normal * metres }
        refit()
    }

    // MARK: - Fine-tuning corners

    func setAdjusting(_ on: Bool) {
        isAdjusting = on
        adjustIndex = nil
        if !on { door?.isEnabled = true }
    }

    /// Corner positions on screen, kept current while a screen is placed so a
    /// touch near a corner can start editing straight away.
    private func updateAdjustHandles() {
        guard cornerPoints.count == 4 else { return }
        let handles = cornerPoints.compactMap { arView.project($0) }
        if handles.count == 4, handles != live.corners.handles { live.corners.handles = handles }
        let outline = fittedOpening?.corners.compactMap { arView.project($0) } ?? []
        if outline.count == 4, outline != live.corners.outline { live.corners.outline = outline }
    }

    // MARK: - Touches on the placed screen

    private enum TouchMode { case none, bar, corner }

    /// One drag on the camera view: near a corner it moves that corner
    /// (entering corner editing), near a pull bar it slides the screen.
    func touchChanged(at location: CGPoint) {
        guard stage == .placed, pickerPurpose == nil else { return }
        if touchMode == .none {
            let corner = nearestCorner(to: location, within: isAdjusting ? 70 : 55)
            let bar = isAdjusting ? nil : nearestBar(to: location, within: 90)
            if let corner, corner.distance <= (bar?.distance ?? .infinity) {
                // Outside corner editing, the handles show only while the finger is down.
                if !isAdjusting {
                    isDraggingCorner = true
                }
                adjustIndex = corner.index
                touchMode = .corner
                // Show only the outline while a corner moves.
                door?.isEnabled = false
                UISelectionFeedbackGenerator().selectionChanged()
            } else if let bar {
                dragTrackIndex = bar.index
                touchMode = .bar
                animation?.cancel()
                if !hasDraggedHandle {
                    hasDraggedHandle = true
                    live.hint.point = nil
                }
                UISelectionFeedbackGenerator().selectionChanged()
            } else {
                return
            }
        }
        switch touchMode {
        case .corner: moveCorner(to: location)
        case .bar: moveBar(to: location)
        case .none: break
        }
    }

    func touchEnded() {
        if touchMode == .corner {
            door?.isEnabled = true
            if isDraggingCorner { isDraggingCorner = false }
            whiteCheckSoon()
        }
        touchMode = .none
        adjustIndex = nil
        dragTrackIndex = nil
    }

    private func nearestCorner(to location: CGPoint, within limit: CGFloat) -> (index: Int, distance: CGFloat)? {
        var best: (index: Int, distance: CGFloat)?
        for (index, handle) in live.corners.handles.enumerated() {
            let distance = hypot(handle.x - location.x, handle.y - location.y)
            if distance < limit, distance < (best?.distance ?? .infinity) { best = (index, distance) }
        }
        return best
    }

    private func nearestBar(to location: CGPoint, within limit: CGFloat) -> (index: Int, distance: CGFloat)? {
        guard let door else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for (index, track) in door.tracks.enumerated() {
            guard let bar = arView.project(door.convert(position: track.bar, to: nil)) else { continue }
            let distance = hypot(bar.x - location.x, bar.y - location.y)
            if distance < limit, distance < (best?.distance ?? .infinity) { best = (index, distance) }
        }
        return best
    }

    private func moveCorner(to location: CGPoint) {
        guard let index = adjustIndex, cornerPoints.count == 4, let opening = fittedOpening else { return }
        // Snap to a real surface near the wall, else slide along the current wall plane.
        var point: SIMD3<Float>?
        if snapCorners {
            let hit = arView.raycast(from: location, allowing: .existingPlaneGeometry, alignment: .any).first
                ?? arView.raycast(from: location, allowing: .estimatedPlane, alignment: .any).first
            if let hit {
                let p = hit.worldTransform.translation
                if abs(dot(p - opening.center, opening.normal)) < 0.12 { point = p }
            }
        }
        if point == nil, let ray = arView.ray(through: location) {
            let denom = dot(ray.direction, opening.normal)
            if abs(denom) > 1e-4 {
                let t = dot(opening.center - ray.origin, opening.normal) / denom
                if t > 0 { point = ray.origin + ray.direction * t }
            }
        }
        guard let point else { return }
        cornerPoints[index] = point
        refit()
    }

    // MARK: - Dragging the pull bar

    private func updateHandleHint() {
        guard !hasDraggedHandle, let door, let track = door.tracks.first,
              let point = arView.project(door.convert(position: track.bar, to: nil)) else {
            if live.hint.point != nil { live.hint.point = nil }
            return
        }
        if let current = live.hint.point, hypot(current.x - point.x, current.y - point.y) < 2 { return }
        live.hint.point = point
    }

    private func moveBar(to location: CGPoint) {
        guard let door, let index = dragTrackIndex, index < door.tracks.count else { return }
        let track = door.tracks[index]
        guard let a = arView.project(door.convert(position: track.start, to: nil)),
              let b = arView.project(door.convert(position: track.end, to: nil)) else { return }
        let abx = b.x - a.x
        let aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        guard lengthSquared > 1 else { return }
        let t = ((location.x - a.x) * abx + (location.y - a.y) * aby) / lengthSquared
        applyExtent(Float(min(max(t, 0), 1)))
    }

    /// Moves the screen without touching `config`, so SwiftUI views that
    /// read the configuration don't redraw every frame of a drag.
    private func applyExtent(_ value: Float) {
        live.screen.extent = value
        door?.setExtent(value)
    }

    func setExtent(_ value: Float) {
        animation?.cancel()
        applyExtent(min(max(value, 0), 1))
    }

    /// Motorized screens: lower, raise and stop at a motor-like pace.
    func lowerScreen() { animate(to: 1, metresPerSecond: 0.35) }
    func raiseScreen() { animate(to: 0, metresPerSecond: 0.35) }
    func stopScreen() { animation?.cancel() }

    /// - Parameter metresPerSecond: constant travel speed; nil eases over about a second.
    private func animate(to target: Float, metresPerSecond: Float? = nil) {
        animation?.cancel()
        let start = live.screen.extent
        let vertical = config.product == .window || config.product.isMotorized
        let travel = vertical ? config.height : config.width
        let eased = max(0.2, Double(abs(target - start)) * 1.1)
        let timed: Double? = metresPerSecond.map { Double(abs(target - start) * travel / $0) }
        let duration = max(0.05, timed ?? eased)
        animation = Task { [weak self] in
            let began = Date()
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(began) / duration)
                let eased = Float(t * t * (3 - 2 * t))
                guard let self else { return }
                self.applyExtent(start + (target - start) * eased)
                if t >= 1 { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    // MARK: - Photos

    func capturePhoto() {
        arView.snapshot(saveToHDR: false) { [weak self] image in
            guard let image else { return }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Keep a reduced copy for the quote; the full photo is in Photos.
                self.photos.append(image.downscaled(maxDimension: 1600))
                if self.photos.count > 8 { self.photos.removeFirst(self.photos.count - 8) }
                self.flash += 1
                self.showToast("Saved to Photos")
            }
        }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// Developer reset: every setting back to its default, white matching
    /// cleared, the saved settings and quote details wiped, and back to
    /// finding an opening. (The welcome screens are shown by the caller.)
    func resetApp() {
        remeasure()
        resetWhiteMatch()
        config = ScreenConfig()
        if sunMode { sunMode = false }
        autoDetect = true
        tapToTarget = false
        showSurfaces = false
        showDiagonal = true
        showRectangle = true
        realisticLighting = true
        occlusion = true
        keepPlumb = true
        snapCorners = true
        brightness = 0
        autoMatchWhite = true
        keepCheckingWhite = false
        showDebug = false
        depthOffWhenPlaced = false
        advancedProductOptions = false
        gloss = .gloss
        sunExposure = .auto
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
    }

    /// A reduced picture of the camera view with the screen, for the review
    /// page. Not saved to Photos.
    func previewSnapshot() async -> UIImage? {
        await withCheckedContinuation { continuation in
            arView.snapshot(saveToHDR: false) { image in
                continuation.resume(returning: image?.downscaled(maxDimension: 1200))
            }
        }
    }

    func showToast(_ text: String, duration: Double = 2.5) {
        toastToken += 1
        let token = toastToken
        live.status.toast = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, self.toastToken == token else { return }
            self.live.status.toast = nil
        }
    }
}

/// State that changes up to every frame, split into small observable pieces
/// so each overlay re-renders only for what it draws. (One shared object made
/// every overlay, sheet and glass panel redraw 60 times a second.)
@MainActor
final class LiveState {
    let detection = DetectionLive()
    let corners = CornerLive()
    let hint = HintLive()
    let picker = PickerLive()
    let screen = ScreenLive()
    let status = StatusLive()
    let trim = TrimLive()
    let debug = DebugLive()
}

/// Toasts and tracking messages.
@MainActor
final class StatusLive: ObservableObject {
    @Published var toast: String?
    @Published var trackingMessage: String?
}

/// The real trim's color as last seen by the automatic white check.
@MainActor
final class TrimLive: ObservableObject {
    @Published var color: UIColor?
    /// ARKit's estimate of the room light's color temperature when the trim
    /// was seen, used to see past warm or cool light.
    @Published var lightKelvin: Float?
}

/// Developer overlay (Settings → Advanced → Debug overlay).
@MainActor
final class DebugLive: ObservableObject {
    @Published var fps = 0
    @Published var method = "—"
    @Published var wall = false
    @Published var outdoors = false
}

@MainActor
final class DetectionLive: ObservableObject {
    @Published var quad: [CGPoint] = []
    /// Projected tap target while finding an opening.
    @Published var target: CGPoint?
}

@MainActor
final class CornerLive: ObservableObject {
    @Published var preview: CornerPreview?
    @Published var handles: [CGPoint] = []
    @Published var outline: [CGPoint] = []
}

@MainActor
final class HintLive: ObservableObject {
    @Published var point: CGPoint?
}

@MainActor
final class PickerLive: ObservableObject {
    /// Camera colour under the picker reticle.
    @Published var color: UIColor?
}

@MainActor
final class ScreenLive: ObservableObject {
    /// 0 = retracted, 1 = closed.
    @Published var extent: Float = 1
}

struct CornerPreview: Equatable {
    var start: CGPoint
    var end: CGPoint
    var quad: [CGPoint]
    var width: Float
    var height: Float
}
