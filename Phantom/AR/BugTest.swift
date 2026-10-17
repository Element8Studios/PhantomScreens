import RealityKit
import UIKit

/// The bug test: a handful of bugs fly at the opening from outside. Where the
/// screen is closed they bounce off and try again somewhere else; where it's
/// open they fly on into the room. After a few seconds a message says how
/// many the screen kept out.
struct BugTest {
    struct Bug {
        let entity: Entity
        /// Left and right wing pivots.
        let wings: [Entity]
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        /// Seconds after the start when this bug sets off.
        let startsAt: Double
        let phase: Float
        var blocked = false
        var gotIn = false
        /// When a bounced bug turns back toward the screen.
        var turnAt: Double?
    }

    static let count = 8
    static let length: Double = 7

    let root: Entity
    let began: Date
    var last: Date
    var bugs: [Bug]
}

extension PhantomSession {
    func startBugTest() {
        guard stage == .placed, isRevealed, !bugTestRunning, let frame = frameEntity, let door else { return }
        let root = Entity()
        frame.addChild(root)
        let plane = door.screenPlaneZ
        let w = config.width
        let h = config.height
        var bugs: [BugTest.Bug] = []
        for i in 0..<BugTest.count {
            let start = SIMD3(Float.random(in: -w / 2 - 0.3...w / 2 + 0.3),
                              Float.random(in: -h / 2...h / 2 + 0.3),
                              plane - Float.random(in: 0.9...1.4))
            let (entity, wings) = Self.makeBug()
            entity.isEnabled = false
            entity.position = start
            root.addChild(entity)
            bugs.append(BugTest.Bug(entity: entity, wings: wings, position: start,
                                    velocity: Self.bugAim(from: start, plane: plane, width: w, height: h),
                                    startsAt: Double(i) * 0.3 + Double.random(in: 0...0.2),
                                    phase: Float.random(in: 0...6.28)))
        }
        bugTest = BugTest(root: root, began: Date(), last: Date(), bugs: bugs)
        bugTestRunning = true
        showToast(door.extent < 0.97 ? "Here come the bugs… close the screen!" : "Here come the bugs…")
    }

    func stopBugTest() {
        bugTest?.root.removeFromParent()
        bugTest = nil
        if bugTestRunning { bugTestRunning = false }
    }

    /// One frame of the bug test (called while placed).
    func stepBugs() {
        guard var test = bugTest, let door else { return }
        let now = Date()
        let dt = Float(min(now.timeIntervalSince(test.last), 0.05))
        test.last = now
        let t = now.timeIntervalSince(test.began)
        let plane = door.screenPlaneZ
        for i in test.bugs.indices {
            var bug = test.bugs[i]
            guard t >= bug.startsAt else { continue }
            bug.entity.isEnabled = true
            if let turn = bug.turnAt, t >= turn {
                bug.turnAt = nil
                bug.velocity = Self.bugAim(from: bug.position, plane: plane,
                                           width: config.width, height: config.height)
            }
            let previous = bug.position
            bug.position += bug.velocity * dt
            if !bug.gotIn, previous.z < plane, bug.position.z >= plane {
                if door.isCovered(x: bug.position.x, y: bug.position.y) {
                    // Bounce off the mesh, back away, then try again.
                    bug.position.z = plane - 0.003
                    bug.velocity = SIMD3(Float.random(in: -0.3...0.3), Float.random(in: -0.15...0.3),
                                         -abs(bug.velocity.z) * 0.5)
                    bug.turnAt = t + Double.random(in: 0.5...0.9)
                    if !bug.blocked { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    bug.blocked = true
                } else {
                    bug.gotIn = true
                }
            }
            let age = Float(t - bug.startsAt)
            let wobble = SIMD3(sin(age * 7 + bug.phase), cos(age * 9 + bug.phase * 1.3), 0) * 0.025
            let shown = bug.position + wobble
            if simd_length(bug.velocity) > 0.01 {
                bug.entity.look(at: shown + simd_normalize(bug.velocity), from: shown, relativeTo: test.root)
            } else {
                bug.entity.position = shown
            }
            let flap = sin(Float(t) * 55 + bug.phase) * 0.8
            bug.wings[0].orientation = simd_quatf(angle: flap, axis: SIMD3(0, 0, 1))
            bug.wings[1].orientation = simd_quatf(angle: -flap, axis: SIMD3(0, 0, 1))
            test.bugs[i] = bug
        }
        bugTest = test
        if t >= BugTest.length { finishBugTest() }
    }

    private func finishBugTest() {
        guard let test = bugTest else { return }
        let total = test.bugs.count
        let gotIn = test.bugs.filter(\.gotIn).count
        stopBugTest()
        if gotIn == 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("Bug test passed: the screen kept out all \(total) bugs.", duration: 3.5)
        } else if gotIn == total {
            showToast("All \(total) bugs got in. Close the screen and try again.", duration: 3.5)
        } else {
            showToast("\(total - gotIn) of \(total) bugs stopped, \(gotIn) got in. Close the screen all the way.",
                      duration: 3.5)
        }
    }

    /// A velocity from `position` toward a random point in the opening,
    /// carrying on into the room.
    private static func bugAim(from position: SIMD3<Float>, plane: Float, width: Float, height: Float) -> SIMD3<Float> {
        let target = SIMD3(Float.random(in: -width * 0.45...width * 0.45),
                           Float.random(in: -height * 0.45...height * 0.45),
                           plane + 0.8)
        let direction = target - position
        guard simd_length(direction) > 0.001 else { return SIMD3(0, 0, 0.7) }
        return simd_normalize(direction) * Float.random(in: 0.6...0.9)
    }

    /// A small black bug with two flapping, see-through wings. Faces -Z.
    private static func makeBug() -> (Entity, [Entity]) {
        let bug = Entity()
        var shell = PhysicallyBasedMaterial()
        shell.baseColor = .init(tint: UIColor(white: 0.04, alpha: 1))
        shell.roughness = .init(floatLiteral: 0.35)
        let body = ModelEntity(mesh: bodyMesh, materials: [shell])
        body.scale = SIMD3(0.75, 0.7, 1.5)
        bug.addChild(body)
        let head = ModelEntity(mesh: headMesh, materials: [shell])
        head.position = SIMD3(0, 0, -0.017)
        bug.addChild(head)

        var wingMaterial = UnlitMaterial(color: UIColor(white: 0.95, alpha: 0.35))
        wingMaterial.blending = .transparent(opacity: 0.35)
        var wings: [Entity] = []
        for side: Float in [-1, 1] {
            let pivot = Entity()
            pivot.position = SIMD3(side * 0.004, 0.007, -0.002)
            // The plane lies in XZ; tilt it back along the body.
            let wing = Entity()
            wing.position = SIMD3(side * 0.012, 0, 0.004)
            wing.orientation = simd_quatf(angle: side * 0.35, axis: SIMD3(0, 1, 0))
            // Planes are one-sided: a flipped copy shows the underside.
            let upper = ModelEntity(mesh: wingMesh, materials: [wingMaterial])
            let lower = ModelEntity(mesh: wingMesh, materials: [wingMaterial])
            lower.orientation = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
            wing.addChild(upper)
            wing.addChild(lower)
            pivot.addChild(wing)
            bug.addChild(pivot)
            wings.append(pivot)
        }
        return (bug, wings)
    }

    private static let bodyMesh = MeshResource.generateSphere(radius: 0.011)
    private static let headMesh = MeshResource.generateSphere(radius: 0.006)
    private static let wingMesh = MeshResource.generatePlane(width: 0.024, depth: 0.014, cornerRadius: 0.006)
}
