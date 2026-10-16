import simd

/// A rectangular opening (window, doorway, ...) measured from two diagonal corners.
///
/// Local frame: +X is the opening's right, +Y its up, +Z is the wall normal
/// pointing into the room (toward the person measuring). The origin is the
/// centre of the opening on the wall plane.
struct Opening: Equatable {
    var center: SIMD3<Float>
    var right: SIMD3<Float>
    var up: SIMD3<Float>
    var normal: SIMD3<Float>
    var width: Float
    var height: Float

    static let minimumSize: Float = 0.15

    var transform: simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(right.x, right.y, right.z, 0),
            SIMD4<Float>(up.x, up.y, up.z, 0),
            SIMD4<Float>(normal.x, normal.y, normal.z, 0),
            SIMD4<Float>(center.x, center.y, center.z, 1)
        ))
    }

    /// Builds an opening from two diagonal corners hit on the wall.
    /// - Parameters:
    ///   - surfaceNormal: normal of the wall at the first corner (either sign).
    ///   - cameraPosition: used to point the normal into the room.
    /// - Returns: nil when the corners are too close to define an opening.
    static func make(
        cornerA: SIMD3<Float>,
        cornerB: SIMD3<Float>,
        surfaceNormal: SIMD3<Float>,
        cameraPosition: SIMD3<Float>
    ) -> Opening? {
        guard length(surfaceNormal) > 1e-4 else { return nil }
        var n = normalize(surfaceNormal)
        let toCamera = cameraPosition - cornerA
        if dot(n, toCamera) < 0 { n = -n }

        // For vertical walls "up" is world up. For floors/ceilings (skylights,
        // hatches) fall back to the direction away from the camera.
        let upReference: SIMD3<Float>
        if abs(n.y) > 0.9 {
            let flat = SIMD3<Float>(toCamera.x, 0, toCamera.z)
            upReference = length(flat) > 1e-4 ? -normalize(flat) : SIMD3<Float>(0, 0, -1)
        } else {
            upReference = SIMD3<Float>(0, 1, 0)
        }

        let right = normalize(cross(upReference, n))
        let up = cross(n, right)

        let diagonal = cornerB - cornerA
        let width = abs(dot(diagonal, right))
        let height = abs(dot(diagonal, up))
        guard width >= minimumSize, height >= minimumSize else { return nil }

        // Midpoint, flattened onto the plane through cornerA.
        var center = cornerA + diagonal / 2
        center -= dot(center - cornerA, n) * n

        return Opening(center: center, right: right, up: up, normal: n, width: width, height: height)
    }
}

extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }

    /// The Y axis of the transform. For ARKit raycast results this is the surface normal.
    var yAxis: SIMD3<Float> {
        SIMD3<Float>(columns.1.x, columns.1.y, columns.1.z)
    }
}

extension Opening {
    /// Top-left, top-right, bottom-right, bottom-left in world space.
    var corners: [SIMD3<Float>] {
        let hw = right * (width / 2)
        let hh = up * (height / 2)
        return [center - hw + hh, center + hw + hh, center + hw - hh, center - hw - hh]
    }
}

/// Pure helpers for depth-based opening detection.
enum DepthEdge {
    /// Index of the first sample that is clearly in front of the opening
    /// (the wall around it), confirmed by the next sample. Samples are depths
    /// in metres walking outward from the centre; `.infinity` means no reading.
    static func firstWall(_ samples: [Float], openingDepth: Float, minGap: Float = 0.25) -> Int? {
        guard samples.count >= 2 else { return nil }
        let limit = openingDepth - minGap
        for i in 0..<(samples.count - 1) {
            let a = samples[i]
            let b = samples[i + 1]
            if a > 0.1, a < limit, b > 0.1, b < limit { return i }
        }
        return nil
    }

    /// The nearest wall along a walk outward from inside an opening.
    ///
    /// Uses the outer half of the walk to find the "near level" (the wall or
    /// trim around the opening), then returns the first index that reaches it.
    /// Things inside the opening that are merely closer than its far side
    /// (furniture, a stair wall in the next room) are skipped.
    static func nearWall(_ samples: [Float], openingDepth: Float, minGap: Float = 0.35) -> Int? {
        guard samples.count >= 4 else { return nil }
        let outer = samples[(samples.count / 2)...].filter { $0.isFinite && $0 > 0.1 }.sorted()
        guard !outer.isEmpty else { return nil }
        let near = outer[outer.count / 4]
        guard near < openingDepth - minGap else { return nil }
        let limit = near + max(0.12, near * 0.06)
        for i in 0..<(samples.count - 1) {
            let a = samples[i]
            let b = samples[i + 1]
            if a > 0.1, a <= limit, b > 0.1, b <= limit { return i }
        }
        return nil
    }

    /// First index whose signed distance to the wall plane is back on (or in
    /// front of) the wall, confirmed by the next sample. Negative distances
    /// are behind the wall, i.e. inside the opening.
    static func firstOnPlane(_ distances: [Float], tolerance: Float = 0.06) -> Int? {
        guard distances.count >= 2 else { return nil }
        for i in 0..<(distances.count - 1) {
            let a = distances[i]
            let b = distances[i + 1]
            if a.isFinite, b.isFinite, a > -tolerance, b > -tolerance { return i }
        }
        return nil
    }

    /// Edge of an opening along a walk outward from inside it, given each
    /// sample's signed distance to the known wall plane (negative: behind the
    /// wall; `-infinity`: no reading). The edge is the first point on the
    /// plane, confirmed by the next sample not being behind it. Points in
    /// front of the wall (an open door leaf, furniture) are walked past, since
    /// an open leaf meets the wall at its hinge; if nothing on the plane is
    /// found, the first of them is used.
    static func planeEdge(_ distances: [Float], tolerance: Float = 0.06) -> Int? {
        guard distances.count >= 2 else { return nil }
        var inFront: Int?
        for i in 0..<(distances.count - 1) {
            let a = distances[i]
            let b = distances[i + 1]
            guard a.isFinite, b.isFinite else { continue }
            if abs(a) <= tolerance, b > -tolerance { return i }
            if a > tolerance, b > tolerance, inFront == nil { inFront = i }
        }
        return inFront
    }

    /// Median of the finite values, or `.infinity` if there are none.
    static func median(_ values: [Float]) -> Float {
        let finite = values.filter { $0.isFinite }.sorted()
        guard !finite.isEmpty else { return .infinity }
        return finite[finite.count / 2]
    }
}

extension Opening {
    /// Best-fit rectangle through four corners (top-left, top-right,
    /// bottom-right, bottom-left), which need not be coplanar or square.
    /// - Parameter plumb: keep the screen vertical (most walls), ignoring lean.
    static func fit(corners c: [SIMD3<Float>], plumb: Bool, cameraPosition: SIMD3<Float>) -> Opening? {
        guard c.count == 4 else { return nil }
        let center = (c[0] + c[1] + c[2] + c[3]) / 4

        // Normal from the cross product of the diagonals.
        var n = cross(c[2] - c[0], c[1] - c[3])
        if plumb { n.y = 0 }
        guard length(n) > 1e-5 else { return nil }
        n = normalize(n)
        if dot(n, cameraPosition - center) < 0 { n = -n }

        var up: SIMD3<Float>
        if plumb {
            up = SIMD3(0, 1, 0)
        } else {
            up = (c[0] - c[3]) + (c[1] - c[2])
            up -= dot(up, n) * n
            guard length(up) > 1e-5 else { return nil }
            up = normalize(up)
            if up.y < 0 { up = -up }
        }
        let right = normalize(cross(up, n))

        let width = (abs(dot(c[1] - c[0], right)) + abs(dot(c[2] - c[3], right))) / 2
        let height = (abs(dot(c[0] - c[3], up)) + abs(dot(c[1] - c[2], up))) / 2
        guard width >= minimumSize, height >= minimumSize else { return nil }
        return Opening(center: center, right: right, up: up, normal: n, width: width, height: height)
    }
}
