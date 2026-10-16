import ARKit
import Metal
import RealityKit
import UIKit

/// The camera for one frame, as plain math: no ARView calls, so it can be
/// used off the main thread.
struct CameraModel {
    var transform: simd_float4x4
    var intrinsics: simd_float3x3
    /// Captured image size in pixels (what the intrinsics refer to).
    var imageSize: CGSize
    /// View-normalized to image-normalized, and back.
    var toImage: CGAffineTransform
    var toView: CGAffineTransform
    var viewSize: CGSize

    init(frame: ARFrame, viewSize: CGSize) {
        transform = frame.camera.transform
        intrinsics = frame.camera.intrinsics
        imageSize = frame.camera.imageResolution
        toView = frame.displayTransform(for: .portrait, viewportSize: viewSize)
        toImage = toView.inverted()
        self.viewSize = viewSize
    }

    init(transform: simd_float4x4, intrinsics: simd_float3x3, imageSize: CGSize,
         toView: CGAffineTransform, viewSize: CGSize) {
        self.transform = transform
        self.intrinsics = intrinsics
        self.imageSize = imageSize
        self.toView = toView
        self.toImage = toView.inverted()
        self.viewSize = viewSize
    }

    var position: SIMD3<Float> { transform.translation }

    /// Image-normalized coordinates (0...1, top-left origin) of a view point.
    func imagePoint(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x / viewSize.width, y: viewPoint.y / viewSize.height).applying(toImage)
    }

    /// World position of a view point at a camera depth (metres along the view axis).
    func unproject(_ viewPoint: CGPoint, depth: Float) -> SIMD3<Float> {
        let image = imagePoint(viewPoint)
        let px = Float(image.x * imageSize.width)
        let py = Float(image.y * imageSize.height)
        let fx = intrinsics[0][0], fy = intrinsics[1][1]
        let cx = intrinsics[2][0], cy = intrinsics[2][1]
        let local = SIMD3<Float>((px - cx) / fx, -(py - cy) / fy, -1) * depth
        let world = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
        return SIMD3(world.x, world.y, world.z)
    }

    /// View point of a world position, or nil behind the camera.
    func project(_ world: SIMD3<Float>) -> CGPoint? {
        let c = transform.inverse * SIMD4<Float>(world.x, world.y, world.z, 1)
        guard c.z < -0.01 else { return nil }
        let fx = intrinsics[0][0], fy = intrinsics[1][1]
        let cx = intrinsics[2][0], cy = intrinsics[2][1]
        let px = fx * c.x / -c.z + cx
        let py = cy - fy * c.y / -c.z
        let image = CGPoint(x: CGFloat(px) / imageSize.width, y: CGFloat(py) / imageSize.height)
        let view = image.applying(toView)
        return CGPoint(x: view.x * viewSize.width, y: view.y * viewSize.height)
    }
}

/// LiDAR opening detection, run on a background queue.
///
/// Start from a point inside the opening (the screen centre, or where the user
/// tapped). When ARKit has found the wall, every depth sample is measured
/// against that wall plane:
/// - Open doorway or window: walking out from the start, the edge is the
///   first point back on the wall plane. Things behind the wall (the next
///   room) are skipped, and so are things in front of it, like an open door
///   leaf: where the leaf meets the wall is its hinge, which is the jamb.
/// - Closed door: the start point is on the wall plane, so depth can't see
///   the opening. ARKit's scene mesh labels door and window surfaces; the
///   labelled area around the start point is the opening.
/// Without a known wall, the left and right edges are where depth reaches
/// the nearest wall level on each side, as before.
enum DepthOpeningDetector {
    struct Input {
        var depth: ARDepthData
        var camera: CameraModel
        var start: CGPoint
        var floorY: Float?
        /// ARKit's vertical planes, for finding the wall around the opening.
        var walls: [WallCandidate] = []
        /// Scene mesh pieces near the camera, with door and window labels.
        var meshes: [ARMeshAnchor] = []
    }

    struct Detection {
        var opening: Opening
        var quad: [CGPoint]
        /// How it was found, for the debug overlay.
        var method: String
        var usedWall: Bool
    }

    static func detect(_ input: Input) -> Detection? {
        let camera = input.camera
        let size = camera.viewSize
        let start = input.start
        guard size.width > 0, size.height > 0,
              CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10).contains(start) else { return nil }
        let step: CGFloat = 5

        func walk(_ dx: CGFloat, _ dy: CGFloat) -> [CGPoint] {
            var points: [CGPoint] = []
            var p = CGPoint(x: start.x + dx * step, y: start.y + dy * step)
            while p.x > 4, p.y > 4, p.x < size.width - 4, p.y < size.height - 4 {
                points.append(p)
                p = CGPoint(x: p.x + dx * step, y: p.y + dy * step)
            }
            return points
        }
        let paths: [[CGPoint]] = [walk(-1, 0), walk(1, 0), walk(0, -1), walk(0, 1)]
        let middle = [-8, 0, 8].flatMap { dx in [-8, 0, 8].map { dy in
            CGPoint(x: start.x + CGFloat(dx), y: start.y + CGFloat(dy))
        } }

        let sampled = sampleDepths(input.depth, points: [middle] + paths, camera: camera)
        let openingDepth = DepthEdge.median(sampled[0])

        let origin = camera.position
        let direction = normalize(camera.unproject(start, depth: 1) - origin)
        let startPoint = openingDepth.isFinite ? camera.unproject(start, depth: openingDepth) : nil
        let seen = startPoint.map { simd_distance($0, origin) } ?? .infinity
        let wall = WallCandidate.choose(input.walls, origin: origin, direction: direction, before: seen)

        var opening: Opening?
        var method = "depth, nearest walls"
        if let wall {
            // No reading (glass, or too far) counts as behind the wall.
            let offset = startPoint.map { wall.distance($0) } ?? -.infinity
            if offset < -0.1 {
                opening = openingOnWall(wall, paths: paths, sampled: sampled, camera: camera, floorY: input.floorY)
                method = "depth, wall plane"
                if opening == nil {
                    opening = openingFromNearWalls(paths: paths, sampled: sampled, openingDepth: openingDepth,
                                                   camera: camera, floorY: input.floorY)
                    method = "depth, nearest walls"
                }
            }
        } else {
            opening = openingFromNearWalls(paths: paths, sampled: sampled, openingDepth: openingDepth,
                                           camera: camera, floorY: input.floorY)
        }

        // A closed door (or nothing found by depth): use ARKit's door and window labels.
        if opening == nil, !input.meshes.isEmpty {
            let focus: SIMD3<Float>
            if let wall, let hit = wall.intersect(origin: origin, direction: direction) {
                focus = hit
            } else {
                focus = startPoint ?? origin + direction * 2.5
            }
            let faces = classifiedFaces(input.meshes, near: focus, radius: 2.6)
            opening = classifiedOpening(faces, origin: origin, direction: direction, wall: wall, floorY: input.floorY)
            method = "door/window labels"
        }

        guard let opening else { return nil }
        let quad = opening.corners.compactMap { camera.project($0) }
        guard quad.count == 4 else { return nil }
        return Detection(opening: opening, quad: quad, method: method, usedWall: wall != nil)
    }

    /// Edges where the walks come back onto a known wall plane.
    static func openingOnWall(_ wall: WallPlane, paths: [[CGPoint]], sampled: [[Float]],
                              camera: CameraModel, floorY: Float?) -> Opening? {
        func edgePoint(_ index: Int) -> SIMD3<Float>? {
            let distances = zip(paths[index], sampled[index + 1]).map { point, depth -> Float in
                depth.isFinite ? wall.distance(camera.unproject(point, depth: depth)) : -.infinity
            }
            guard let i = DepthEdge.planeEdge(distances) else { return nil }
            return wall.project(camera.unproject(paths[index][i], depth: sampled[index + 1][i]))
        }
        guard let left = edgePoint(0), let right = edgePoint(1), let top = edgePoint(2) else { return nil }
        var bottomY: Float
        if let bottom = edgePoint(3) {
            bottomY = bottom.y
            if let floorY, abs(bottomY - floorY) < 0.08 { bottomY = floorY }
        } else if let floorY {
            bottomY = floorY
        } else {
            return nil
        }
        let axis = wall.rightAxis
        return wall.opening(left: dot(left, axis), right: dot(right, axis), top: top.y, bottom: bottomY)
    }

    /// Without a known wall: the nearest wall level on each side gives the
    /// wall plane, then up and down come back onto it.
    static func openingFromNearWalls(paths: [[CGPoint]], sampled: [[Float]], openingDepth: Float,
                                     camera: CameraModel, floorY: Float?) -> Opening? {
        guard let li = DepthEdge.nearWall(sampled[1], openingDepth: openingDepth),
              let ri = DepthEdge.nearWall(sampled[2], openingDepth: openingDepth) else { return nil }
        let left = camera.unproject(paths[0][li], depth: sampled[1][li])
        let right = camera.unproject(paths[1][ri], depth: sampled[2][ri])

        // A vertical wall: horizontal right vector, normal toward the camera.
        var across = right - left
        across.y = 0
        guard length(across) > 0.2 else { return nil }
        var normal = cross(normalize(across), SIMD3<Float>(0, 1, 0))
        if dot(normal, camera.position - left) < 0 { normal = -normal }
        let wall = WallPlane(point: (left + right) / 2, normal: normal)

        // Up and down: back onto the wall plane.
        func planeDistances(_ index: Int) -> [Float] {
            zip(paths[index], sampled[index + 1]).map { point, depth in
                guard depth.isFinite else { return -.infinity }
                return wall.distance(camera.unproject(point, depth: depth))
            }
        }
        guard let ti = DepthEdge.firstOnPlane(planeDistances(2)) else { return nil }
        let top = camera.unproject(paths[2][ti], depth: sampled[3][ti])

        let bottomY: Float
        if let bi = DepthEdge.firstOnPlane(planeDistances(3)) {
            bottomY = camera.unproject(paths[3][bi], depth: sampled[4][bi]).y
        } else if let floorY {
            bottomY = floorY
        } else {
            return nil
        }
        let axis = wall.rightAxis
        return wall.opening(left: dot(left, axis), right: dot(right, axis), top: top.y, bottom: bottomY)
    }

    // MARK: - Door and window labels

    /// One scene-mesh triangle labelled door or window, in world space.
    struct ClassifiedFace {
        var a: SIMD3<Float>
        var b: SIMD3<Float>
        var c: SIMD3<Float>
        var isWindow: Bool
    }

    /// Door and window triangles per mesh anchor, in the anchor's own space,
    /// keyed by its face count. Mesh pieces change only now and then, so most
    /// detection passes reuse these. Only touched on the detection queue.
    private static var labelCache: [UUID: (faceCount: Int, faces: [ClassifiedFace])] = [:]

    /// Door and window triangles of the scene mesh within `radius` of a point.
    static func classifiedFaces(_ anchors: [ARMeshAnchor], near point: SIMD3<Float>, radius: Float) -> [ClassifiedFace] {
        if labelCache.count > 500 { labelCache.removeAll() }
        var faces: [ClassifiedFace] = []
        for anchor in anchors {
            let geometry = anchor.geometry
            let local: [ClassifiedFace]
            if let cached = labelCache[anchor.identifier], cached.faceCount == geometry.faces.count {
                local = cached.faces
            } else {
                local = labelledFaces(geometry)
                labelCache[anchor.identifier] = (faceCount: geometry.faces.count, faces: local)
            }
            let transform = anchor.transform
            func world(_ p: SIMD3<Float>) -> SIMD3<Float> {
                let w = transform * SIMD4<Float>(p.x, p.y, p.z, 1)
                return SIMD3(w.x, w.y, w.z)
            }
            for face in local {
                let a = world(face.a)
                guard simd_distance(a, point) < radius else { continue }
                faces.append(ClassifiedFace(a: a, b: world(face.b), c: world(face.c), isWindow: face.isWindow))
            }
        }
        return faces
    }

    /// The door and window triangles of one mesh piece, in its own space.
    private static func labelledFaces(_ geometry: ARMeshGeometry) -> [ClassifiedFace] {
        let door = UInt8(ARMeshClassification.door.rawValue)
        let window = UInt8(ARMeshClassification.window.rawValue)
        guard let labels = geometry.classification,
              geometry.faces.indexCountPerPrimitive == 3 else { return [] }
        let vertices = geometry.vertices
        let vertexBase = UnsafeRawPointer(vertices.buffer.contents()).advanced(by: vertices.offset)
        let indexBase = UnsafeRawPointer(geometry.faces.buffer.contents())
        let indexSize = geometry.faces.bytesPerIndex
        let labelBase = UnsafeRawPointer(labels.buffer.contents()).advanced(by: labels.offset)

        func vertex(_ i: Int) -> SIMD3<Float> {
            let p = vertexBase.advanced(by: i * vertices.stride)
            return SIMD3(p.loadUnaligned(as: Float.self),
                         p.loadUnaligned(fromByteOffset: 4, as: Float.self),
                         p.loadUnaligned(fromByteOffset: 8, as: Float.self))
        }
        func index(_ i: Int) -> Int {
            indexSize == 2
                ? Int(indexBase.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                : Int(indexBase.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
        }

        var faces: [ClassifiedFace] = []
        for f in 0..<geometry.faces.count {
            let label = labelBase.loadUnaligned(fromByteOffset: f * labels.stride, as: UInt8.self)
            guard label == door || label == window else { continue }
            faces.append(ClassifiedFace(a: vertex(index(f * 3)), b: vertex(index(f * 3 + 1)),
                                        c: vertex(index(f * 3 + 2)), isWindow: label == window))
        }
        return faces
    }

    /// The labelled door or window around the ray, as an opening on the wall
    /// (or on the door itself when the wall isn't known).
    static func classifiedOpening(_ faces: [ClassifiedFace], origin: SIMD3<Float>, direction: SIMD3<Float>,
                                  wall: WallPlane?, floorY: Float?) -> Opening? {
        struct Info {
            var face: Int
            var center: SIMD3<Float>
            var normal: SIMD3<Float>
            var area: Float
            var along: Float
            var off: Float
        }
        var infos: [Info] = []
        infos.reserveCapacity(faces.count)
        for (i, f) in faces.enumerated() {
            let crossed = cross(f.b - f.a, f.c - f.a)
            let doubled = length(crossed)
            guard doubled > 1e-7 else { continue }
            let center = (f.a + f.b + f.c) / 3
            var normal = crossed / doubled
            if dot(normal, origin - center) < 0 { normal = -normal }
            let along = dot(center - origin, direction)
            guard along > 0.3 else { continue }
            let off = length(center - origin - direction * along)
            infos.append(Info(face: i, center: center, normal: normal, area: doubled / 2, along: along, off: off))
        }

        // Labelled surfaces where the user is aiming.
        var seeds = infos.filter { $0.off < 0.45 }
        guard seeds.count >= 8 else { return nil }
        let isWindow = seeds.filter { faces[$0.face].isWindow }.count * 2 > seeds.count
        seeds = seeds.filter { faces[$0.face].isWindow == isWindow }
        guard seeds.count >= 6 else { return nil }
        let seedPoint = origin + direction * DepthEdge.median(seeds.map(\.along))

        var normal: SIMD3<Float>
        if let wall {
            normal = wall.normal
        } else {
            normal = seeds.reduce(SIMD3<Float>.zero) { $0 + $1.normal * $1.area }
            normal.y = 0
            guard length(normal) > 1e-6 else { return nil }
            normal = normalize(normal)
        }
        let plane = wall ?? WallPlane(point: seedPoint, normal: normal)
        let axis = plane.rightAxis
        let seedX = dot(seedPoint, axis)

        // Same kind, facing the room, in the same plane as where the user aims
        // (an open door leaf faces sideways and is left out).
        var cluster: [Info] = []
        for info in infos where faces[info.face].isWindow == isWindow {
            let depth: Float = abs(dot(info.center - seedPoint, normal))
            let facing: Float = abs(dot(info.normal, normal))
            let sideways: Float = abs(dot(info.center, axis) - seedX)
            let vertical: Float = abs(info.center.y - seedPoint.y)
            if depth < 0.2, facing > 0.7, sideways < 1.9, vertical < 2.6 { cluster.append(info) }
        }
        guard cluster.count >= 8 else { return nil }

        // Keep only the patch connected to the aim point, across and up and
        // down (5 cm bins, small gaps allowed), so a second door along the
        // wall or a stray label isn't merged in.
        let binSize: Float = 0.05
        func connected(_ value: (Info) -> Float, from base: Float) -> ClosedRange<Int>? {
            func bin(_ v: Float) -> Int { Int(((v - base) / binSize).rounded(.down)) }
            let occupied = Set(cluster.map { bin(value($0)) })
            guard let first = occupied.min(by: { abs($0) < abs($1) }), abs(first) <= 10 else { return nil }
            var low = first
            var high = first
            while let next = (1...3).map({ low - $0 }).first(where: occupied.contains) { low = next }
            while let next = (1...3).map({ high + $0 }).first(where: occupied.contains) { high = next }
            return low...high
        }
        func across(_ info: Info) -> Float { dot(info.center, axis) }
        func height(_ info: Info) -> Float { info.center.y }
        guard let columns = connected(across, from: seedX),
              let rows = connected(height, from: seedPoint.y) else { return nil }
        func inRange(_ value: Float, _ base: Float, _ range: ClosedRange<Int>) -> Bool {
            range.contains(Int(((value - base) / binSize).rounded(.down)))
        }

        var xs: [Float] = []
        var ys: [Float] = []
        for info in cluster where inRange(across(info), seedX, columns) && inRange(height(info), seedPoint.y, rows) {
            let f = faces[info.face]
            for v in [f.a, f.b, f.c] {
                xs.append(dot(v, axis))
                ys.append(v.y)
            }
        }
        guard xs.count >= 24 else { return nil }
        xs.sort()
        ys.sort()
        func percentile(_ values: [Float], _ p: Float) -> Float {
            values[min(values.count - 1, max(0, Int(Float(values.count - 1) * p)))]
        }
        let left = percentile(xs, 0.005)
        let right = percentile(xs, 0.995)
        let top = percentile(ys, 0.995)
        var bottom = percentile(ys, 0.005)
        if !isWindow, let floorY, bottom - floorY < 0.15 { bottom = floorY }
        guard right - left >= 0.35, top - bottom >= 0.35 else { return nil }
        return plane.opening(left: left, right: right, top: top, bottom: bottom)
    }

    /// Reads depth (metres) at view points; low-confidence or missing readings are `.infinity`.
    static func sampleDepths(_ data: ARDepthData, points: [[CGPoint]], camera: CameraModel) -> [[Float]] {
        let depthMap = data.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let confidence = data.confidenceMap
        if let confidence { CVPixelBufferLockBaseAddress(confidence, .readOnly) }
        defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else {
            return points.map { $0.map { _ in Float.infinity } }
        }
        let confBase = confidence.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confRowBytes = confidence.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        return points.map { path in
            path.map { point in
                let normalized = camera.imagePoint(point)
                let x = Int(normalized.x * CGFloat(width))
                let y = Int(normalized.y * CGFloat(height))
                guard x >= 0, y >= 0, x < width, y < height else { return Float.infinity }
                if let confBase {
                    let level = confBase.advanced(by: y * confRowBytes).assumingMemoryBound(to: UInt8.self)[x]
                    if level == UInt8(ARConfidenceLevel.low.rawValue) { return Float.infinity }
                }
                let value = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)[x]
                return value.isFinite && value > 0 ? value : Float.infinity
            }
        }
    }
}

/// A vertical wall: a point on it and its horizontal normal toward the camera.
struct WallPlane: Equatable {
    var point: SIMD3<Float>
    var normal: SIMD3<Float>

    /// Signed distance from the wall; negative is behind it (inside the opening).
    func distance(_ p: SIMD3<Float>) -> Float { dot(p - point, normal) }

    func project(_ p: SIMD3<Float>) -> SIMD3<Float> { p - distance(p) * normal }

    var rightAxis: SIMD3<Float> { normalize(cross(SIMD3<Float>(0, 1, 0), normal)) }

    func intersect(origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>? {
        let denom = dot(direction, normal)
        guard abs(denom) > 1e-4 else { return nil }
        let t = dot(point - origin, normal) / denom
        return t > 0 ? origin + direction * t : nil
    }

    /// The rectangle between edges given along `rightAxis` and in world height.
    func opening(left: Float, right: Float, top: Float, bottom: Float) -> Opening? {
        let width = right - left
        let height = top - bottom
        guard ScreenConfig.widthRange.contains(width), ScreenConfig.heightRange.contains(height) else { return nil }
        let axis = rightAxis
        var center = point + axis * ((left + right) / 2 - dot(point, axis))
        center.y = (top + bottom) / 2
        center = project(center)
        return Opening(center: center, right: axis, up: SIMD3(0, 1, 0), normal: normal,
                       width: width, height: height)
    }
}

/// One of ARKit's vertical planes, as a possible wall around the opening.
struct WallCandidate {
    var plane: WallPlane
    /// 0 for a plane ARKit labels as wall; more for doors, windows or unknown.
    var penalty: Float
    /// The plane anchor's transform and its extent in local x and z.
    var transform: simd_float4x4
    var minimum: SIMD2<Float>
    var maximum: SIMD2<Float>

    /// How far a point on the plane lies outside the plane's known extent.
    func outside(_ p: SIMD3<Float>) -> Float {
        let local = transform.inverse * SIMD4<Float>(p.x, p.y, p.z, 1)
        let dx = max(minimum.x - local.x, 0, local.x - maximum.x)
        let dz = max(minimum.y - local.z, 0, local.z - maximum.y)
        return (dx * dx + dz * dz).squareRoot()
    }

    init(plane: WallPlane, penalty: Float, transform: simd_float4x4, minimum: SIMD2<Float>, maximum: SIMD2<Float>) {
        self.plane = plane
        self.penalty = penalty
        self.transform = transform
        self.minimum = minimum
        self.maximum = maximum
    }

    init?(_ anchor: ARPlaneAnchor, cameraPosition: SIMD3<Float>) {
        guard anchor.alignment == .vertical else { return nil }
        var normal = anchor.transform.yAxis
        normal.y = 0
        guard length(normal) > 0.5 else { return nil }
        normal = normalize(normal)
        let point = anchor.transform.translation
        if dot(normal, cameraPosition - point) < 0 { normal = -normal }
        let boundary = anchor.geometry.boundaryVertices
        guard !boundary.isEmpty else { return nil }
        var low = SIMD2<Float>(repeating: .infinity)
        var high = SIMD2<Float>(repeating: -.infinity)
        for v in boundary {
            low = simd_min(low, SIMD2(v.x, v.z))
            high = simd_max(high, SIMD2(v.x, v.z))
        }
        let penalty: Float
        switch anchor.classification {
        case .wall: penalty = 0
        case .door, .window: penalty = 1
        default: penalty = 0.3
        }
        self.init(plane: WallPlane(point: point, normal: normal), penalty: penalty,
                  transform: anchor.transform, minimum: low, maximum: high)
    }

    /// The wall the ray through the opening crosses: in front of (or at) what
    /// the camera sees there, facing the camera, and near a known part of the
    /// plane. The nearest such plane wins: anything nearer that covered the
    /// ray would hide what's behind it, unless the ray passes through a hole
    /// in it, which is the opening. A wall seen through the opening is
    /// further away. Planes labelled door or window count as further still.
    static func choose(_ candidates: [WallCandidate], origin: SIMD3<Float>, direction: SIMD3<Float>,
                       before limit: Float) -> WallPlane? {
        var best: (score: Float, plane: WallPlane)?
        for candidate in candidates {
            let n = candidate.plane.normal
            let denom = dot(direction, n)
            guard denom < -0.3 else { continue }
            let t = dot(candidate.plane.point - origin, n) / denom
            guard t > 0.3, t < 8, t <= limit + 0.15 else { continue }
            let outside = candidate.outside(origin + direction * t)
            guard outside < 1.0 else { continue }
            let score = t + candidate.penalty * 0.5 + outside * 0.5
            if score < (best?.score ?? .infinity) { best = (score, candidate.plane) }
        }
        return best?.plane
    }
}

extension PhantomSession {
    /// Depth (metres) at one view point, or nil without LiDAR depth.
    func depth(at point: CGPoint, in frame: ARFrame) -> Float? {
        guard let data = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let camera = CameraModel(frame: frame, viewSize: arView.bounds.size)
        let value = DepthOpeningDetector.sampleDepths(data, points: [[point]], camera: camera)[0][0]
        return value.isFinite ? value : nil
    }

    /// World position of a screen point at a given camera depth (metres along the view axis).
    func unproject(_ point: CGPoint, depth: Float) -> SIMD3<Float>? {
        guard depth.isFinite, let frame = arView.session.currentFrame else { return nil }
        return CameraModel(frame: frame, viewSize: arView.bounds.size).unproject(point, depth: depth)
    }

    func floorHeight(_ frame: ARFrame) -> Float? {
        let cameraY = frame.camera.transform.translation.y
        let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal }
        if let floor = planes.first(where: { $0.classification == .floor }) {
            return floor.transform.translation.y
        }
        return planes.map { $0.transform.translation.y }.filter { $0 < cameraY - 0.6 }.min()
    }
}
