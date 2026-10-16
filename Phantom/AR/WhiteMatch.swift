import RealityKit
import UIKit

/// Matches the rendered frame to the real trim around the opening.
///
/// Takes a snapshot of the view (camera image plus the rendered screen) and
/// samples a ring of points just outside the opening and its hardware. The
/// samples closest to white (bright and neutral: the trim, not the wall's
/// shadows or the floor) are averaged as the reference white. The rendered
/// frame is sampled on its housing, then the virtual exposure and color gain
/// are nudged until the two agree. A few rounds converge because each one
/// measures the actual result, and corrections ease in rather than jump.
///
/// With "Match white to trim automatically" on, this runs once, when the
/// screen has faded in. Settings → Advanced → Keep re-checking white repeats
/// it every few seconds (off by default, since it can visibly shift).
extension PhantomSession {
    /// - Parameters:
    ///   - trimPoint: a screen point on the trim picked by the user; nil
    ///     samples the trim automatically around the opening.
    ///   - background: a quiet periodic check: no spinner or message, and
    ///     small differences are left alone.
    func matchWhiteToTrim(announce: Bool = true, delay: Double = 0, trimPoint: CGPoint? = nil,
                          background: Bool = false) {
        guard fittedOpening != nil, !isMatchingWhite else { return }
        if background {
            guard !isCheckingWhite else { return }
            isCheckingWhite = true
        } else {
            whiteMatchTask?.cancel()
            isCheckingWhite = false
            isMatchingWhite = true
            whitePickedByUser = trimPoint != nil
        }
        if comparing { comparing = false }
        lastWhiteCheck = Date()
        whiteMatchTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            var outcome = trimPoint == nil
                ? "Couldn't see the trim. Step back so the trim around the opening is in view."
                : "Keep the screen's frame in view while you aim at the trim."
            var unchanged = false
            for round in 0..<4 {
                guard let self, !Task.isCancelled else { return }
                await self.waitForAppearance()
                guard !Task.isCancelled,
                      let image = await self.snapshot(),
                      let result = self.measureWhite(in: image, trimPoint: trimPoint) else { break }
                outcome = "White matched to your trim."
                if trimPoint == nil {
                    self.live.trim.color = Self.srgbColor(result.trim)
                    self.live.trim.lightKelvin = self.arView.session.currentFrame?.lightEstimate
                        .map { Float($0.ambientColorTemperature) }
                }
                // A background check ignores small differences (no jitter).
                let deadband: Float = background && round == 0 ? 0.12 : 0
                if self.applyWhiteCorrection(trim: result.trim, frame: result.frame, deadband: deadband) {
                    unchanged = background && round == 0
                    break
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.lastWhiteCheck = Date()
            // Check less often while nothing changes (up to every 15 s).
            self.whiteCheckInterval = unchanged ? min(self.whiteCheckInterval * 1.5, 15) : 4
            if background {
                self.isCheckingWhite = false
            } else {
                self.isMatchingWhite = false
                if announce { self.showToast(outcome, duration: 3) }
            }
        }
    }

    func resetWhiteMatch() {
        whiteMatchTask?.cancel()
        isMatchingWhite = false
        isCheckingWhite = false
        whitePickedByUser = false
        matchedExposure = 0
        colorGain = SIMD3(repeating: 1)
        applyExposure()
    }

    /// Called every frame while a screen is placed; starts a quiet check
    /// every few seconds when nothing else is going on.
    func checkWhiteIfDue() {
        guard autoMatchWhite, keepCheckingWhite, isRevealed, !whitePickedByUser, !isMatchingWhite, !isCheckingWhite,
              !menuOpen, !comparing, !isAdjusting, !isDraggingCorner, pickerPurpose == nil,
              Date().timeIntervalSince(lastWhiteCheck) > whiteCheckInterval else { return }
        matchWhiteToTrim(announce: false, background: true)
    }

    /// Brings the next quiet check forward, e.g. after the frame colour or fit changed.
    func whiteCheckSoon() {
        whiteCheckInterval = 4
        lastWhiteCheck = min(lastWhiteCheck, Date().addingTimeInterval(-3.4))
    }

    /// Waits until eased exposure and colour changes have finished, plus a
    /// frame or two so the snapshot shows the result.
    private func waitForAppearance() async {
        let began = Date()
        while !appearanceSettled, Date().timeIntervalSince(began) < 1.5, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    private func snapshot() async -> UIImage? {
        await withCheckedContinuation { continuation in
            arView.snapshot(saveToHDR: false) { image in continuation.resume(returning: image) }
        }
    }

    /// Linear RGB of the real trim and the rendered frame, or nil if not visible.
    private func measureWhite(in image: UIImage, trimPoint: CGPoint? = nil) -> (trim: SIMD3<Float>, frame: SIMD3<Float>)? {
        guard let o = fittedOpening, let cg = image.cgImage else { return nil }
        let scale = CGFloat(cg.width) / max(arView.bounds.width, 1)
        // Sample the painted hardware on its flat front face: the door
        // housing on the retract side (both sides for doubles), or the
        // housing or headbox across the top.
        let hw = o.width / 2
        let hh = o.height / 2
        let hardware = ScreenDoorEntity.hardware(for: config)
        let mountOffset: Float = config.mount == .outside ? ScreenDoorEntity.mountDepth(for: config) / 2 + 0.01 : 0
        let doorFront = o.normal * (hardware.housingDepth / 2 + mountOffset)
        let top = o.center + o.up * hh

        func housingPoints(side: Float) -> [SIMD3<Float>] {
            let x = o.center + o.right * side * (hw + hardware.housingWidth / 2) + doorFront
            return [x + o.up * (o.height * 0.25), x - o.up * (o.height * 0.25)]
        }
        /// Two points on the front of a box of `size` lying across the top.
        func topPoints(size: Float) -> [SIMD3<Float>] {
            let center = top + o.up * (size / 2) + o.normal * (size / 2 + mountOffset)
            return [center - o.right * (o.width * 0.25), center + o.right * (o.width * 0.25)]
        }

        // How far the hardware reaches past each edge of the opening, so the
        // real surroundings are sampled beyond it: left, right, top, bottom
        // (nil: don't sample that side; below a door is floor, not trim).
        let reach: (left: Float, right: Float, top: Float, bottom: Float?)
        var framePoints: [SIMD3<Float>] = []
        switch config.product {
        case .single, .sliding, .oversized, .double:
            let track = ScreenDoorEntity.trackThickness
            if ScreenDoorEntity.hasTwoHousings(config) {
                framePoints = housingPoints(side: -1) + housingPoints(side: 1)
                reach = (left: hardware.housingWidth, right: hardware.housingWidth, top: track, bottom: nil)
            } else {
                let s: Float = config.side == .left ? -1 : 1
                framePoints = housingPoints(side: s)
                // The far side has the closed pull bar and end clip.
                let far = hardware.barWidth + 0.03
                if s < 0 {
                    reach = (left: hardware.housingWidth, right: far, top: track, bottom: nil)
                } else {
                    reach = (left: far, right: hardware.housingWidth, top: track, bottom: nil)
                }
            }
        case .window:
            framePoints = topPoints(size: ScreenDoorEntity.windowHousing)
            let track = ScreenDoorEntity.trackThickness
            reach = (left: track, right: track, top: ScreenDoorEntity.windowHousing, bottom: ScreenDoorEntity.barWidth)
        case .motorized:
            framePoints = topPoints(size: ScreenDoorEntity.headbox)
            let track = ScreenDoorEntity.sideTrackWidth
            reach = (left: track, right: track, top: ScreenDoorEntity.headbox, bottom: nil)
        }

        // A ring of points around the opening, just past the hardware.
        var trimPoints: [SIMD3<Float>] = []
        let along: [Float] = [-0.8, -0.4, 0, 0.4, 0.8]
        for gap: Float in [0.03, 0.07, 0.11] {
            for t in along {
                trimPoints.append(o.center - o.right * (hw + reach.left + gap) + o.up * (t * hh))
                trimPoints.append(o.center + o.right * (hw + reach.right + gap) + o.up * (t * hh))
                trimPoints.append(top + o.up * (reach.top + gap) + o.right * (t * hw))
                if let bottom = reach.bottom {
                    trimPoints.append(o.center - o.up * (hh + bottom + gap) + o.right * (t * hw))
                }
            }
        }

        func samples(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
            points.compactMap { point -> SIMD3<Float>? in
                guard let screen = arView.project(point),
                      arView.bounds.insetBy(dx: 8, dy: 8).contains(screen) else { return nil }
                return Self.averageLinear(cg, at: CGPoint(x: screen.x * scale, y: screen.y * scale))
            }
        }
        let trim: [SIMD3<Float>]
        if let trimPoint {
            trim = [Self.averageLinear(cg, at: CGPoint(x: trimPoint.x * scale, y: trimPoint.y * scale))].compactMap { $0 }
        } else {
            trim = Self.whitest(samples(trimPoints))
        }
        let frame = samples(framePoints)
        guard !trim.isEmpty, frame.count >= 2 else { return nil }
        let t = trimPoint == nil ? Self.mean(trim) : Self.median(trim)
        let f = Self.median(frame)
        guard Self.luma(t) > 0.02, Self.luma(f) > 0.005 else { return nil }
        return (t, f)
    }

    /// Sets new targets for exposure and colour gain. Returns true once the
    /// frame is within about 4% of the trim (or within `deadband` stops, in
    /// which case nothing changes).
    private func applyWhiteCorrection(trim: SIMD3<Float>, frame: SIMD3<Float>, deadband: Float = 0) -> Bool {
        let ratio = Self.luma(trim) / Self.luma(frame)
        // Only match colour when the chosen frame is white; otherwise the
        // trim's colour says nothing about how the paint should look.
        let matchColour = config.finish == .classicWhite
        let trimChroma = trim / Self.luma(trim)
        let frameChroma = frame / Self.luma(frame)
        let chromaRatio = trimChroma / frameChroma
        let chromaOff = matchColour
            ? max(abs(log2(chromaRatio.x)), abs(log2(chromaRatio.y)), abs(log2(chromaRatio.z)))
            : 0
        if deadband > 0, abs(log2(ratio)) < deadband, chromaOff < deadband { return true }

        let step = min(max(log2(ratio), -1), 1)
        matchedExposure = min(max(matchedExposure + step * 0.85, -1.5), 2.5)
        if matchColour {
            var gain = colorGain * SIMD3<Float>(
                pow(chromaRatio.x, 0.8), pow(chromaRatio.y, 0.8), pow(chromaRatio.z, 0.8))
            gain /= max(gain.x, max(gain.y, gain.z))
            colorGain = gain.clamped(lowerBound: SIMD3(repeating: 0.75), upperBound: SIMD3(repeating: 1))
        }
        applyExposure()
        return abs(log2(ratio)) < 0.06
    }

    // MARK: - Pixel helpers

    static func luma(_ c: SIMD3<Float>) -> Float {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }

    /// The samples closest to white: bright and neutral. Walls, shadows,
    /// floors and furniture around the opening drop out; the trim stays.
    static func whitest(_ samples: [SIMD3<Float>]) -> [SIMD3<Float>] {
        func whiteness(_ c: SIMD3<Float>) -> Float {
            let high = max(c.x, max(c.y, c.z))
            let low = min(c.x, min(c.y, c.z))
            let spread = high > 1e-4 ? (high - low) / high : 1
            return luma(c) * max(0, 1 - spread)
        }
        let ranked = samples.sorted { whiteness($0) > whiteness($1) }
        let keep = max(3, ranked.count * 3 / 10)
        return Array(ranked.prefix(keep))
    }

    static func mean(_ values: [SIMD3<Float>]) -> SIMD3<Float> {
        values.reduce(SIMD3<Float>.zero, +) / Float(max(values.count, 1))
    }

    static func median(_ values: [SIMD3<Float>]) -> SIMD3<Float> {
        func m(_ v: [Float]) -> Float { let s = v.sorted(); return s[s.count / 2] }
        return SIMD3(m(values.map(\.x)), m(values.map(\.y)), m(values.map(\.z)))
    }

    /// Mean linear RGB of a 9×9 pixel patch.
    static func averageLinear(_ image: CGImage, at point: CGPoint) -> SIMD3<Float>? {
        let size = 9
        let rect = CGRect(x: Int(point.x) - size / 2, y: Int(point.y) - size / 2, width: size, height: size)
        guard let patch = image.cropping(to: rect) else { return nil }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(patch, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }
        var sum = SIMD3<Float>.zero
        for i in 0..<(size * size) {
            sum += SIMD3(srgbToLinear(pixels[i * 4]), srgbToLinear(pixels[i * 4 + 1]), srgbToLinear(pixels[i * 4 + 2]))
        }
        return sum / Float(size * size)
    }

    /// Linear RGB back to an sRGB color.
    static func srgbColor(_ linear: SIMD3<Float>) -> UIColor {
        func encode(_ c: Float) -> CGFloat {
            let v = min(max(c, 0), 1)
            return CGFloat(v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        return UIColor(red: encode(linear.x), green: encode(linear.y), blue: encode(linear.z), alpha: 1)
    }

    static func srgbToLinear(_ value: UInt8) -> Float {
        let c = Float(value) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}
