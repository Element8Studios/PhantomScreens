import RealityKit
import UIKit

/// White balance: makes the rendered frame sit in the scene's light.
///
/// Takes a snapshot of the view (camera image plus the rendered screen). The
/// reference is the scene's own white: the brightest neutral surfaces in
/// view, away from the screen, ignoring clipped areas like sky, lamps and
/// glare. Nothing is assumed about the trim, which may not be white at all.
/// The rendered frame is sampled on the flat front of its housing, then the
/// virtual exposure and a gentle color gain are nudged until the frame's
/// white sits like a real white surface in that light. A few rounds converge
/// because each one measures the actual result, and corrections ease in.
///
/// Picking a white surface by hand (Settings → Advanced) uses that point as
/// the reference instead, matched fully.
///
/// With "Match white automatically" on, this runs once, when the screen has
/// faded in. Settings → Advanced → Keep re-checking white repeats it every
/// few seconds (off by default, since it can visibly shift).
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
        lastWhiteCheck = Date()
        whiteMatchTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            var outcome = trimPoint == nil
                ? "Couldn't measure the light. Step back so more of the room is in view."
                : "Keep the screen's frame in view while you aim at something white."
            var unchanged = false
            for round in 0..<4 {
                guard let self, !Task.isCancelled else { return }
                await self.waitForAppearance()
                guard !Task.isCancelled,
                      let image = await self.snapshot(),
                      let result = self.measureWhite(in: image, trimPoint: trimPoint) else { break }
                outcome = trimPoint == nil ? "White balanced to the room's light." : "White matched to the surface you picked."
                if trimPoint == nil, let surround = result.surround {
                    // Seen relative to the room's own white (measured in the
                    // same picture), the color of the light drops out: white
                    // trim under warm bulbs comes out white, almond still
                    // comes out warmer than the room's white.
                    self.live.trim.color = Self.srgbColor(Self.relative(surround, to: result.trim))
                    self.live.trim.lightKelvin = nil
                }
                // A background check ignores small differences (no jitter).
                let deadband: Float = background && round == 0 ? 0.12 : 0
                if self.applyWhiteCorrection(trim: result.trim, frame: result.frame, deadband: deadband,
                                             picked: trimPoint != nil) {
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
              !menuOpen, !isAdjusting, !isDraggingCorner, pickerPurpose == nil,
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

    /// Linear RGB of the reference white and the rendered frame, or nil if
    /// either can't be seen; plus the real trim's color around the opening
    /// (for the closest-color suggestion), if it was in view.
    private func measureWhite(in image: UIImage, trimPoint: CGPoint? = nil)
        -> (trim: SIMD3<Float>, frame: SIMD3<Float>, surround: SIMD3<Float>?)? {
        guard let o = fittedOpening, let door, let cg = image.cgImage else { return nil }
        let scale = CGFloat(cg.width) / max(arView.bounds.width, 1)
        let bounds = arView.bounds.insetBy(dx: 8, dy: 8)

        // The rendered frame, on the front of its housing or headbox.
        let frame: [SIMD3<Float>] = door.paintSamplePoints.compactMap { local in
            guard let screen = arView.project(door.convert(position: local, to: nil)),
                  bounds.contains(screen) else { return nil }
            return Self.averageLinear(cg, at: CGPoint(x: screen.x * scale, y: screen.y * scale))
        }

        let reference: SIMD3<Float>?
        if let trimPoint {
            reference = Self.averageLinear(cg, at: CGPoint(x: trimPoint.x * scale, y: trimPoint.y * scale))
        } else {
            // Leave out the screen and its hardware (with a margin), and the
            // sky at the top of the view when outdoors.
            var around = o
            around.width += 0.5
            around.height += 0.5
            let region = around.corners.compactMap { arView.project($0) }
            reference = Self.sceneWhite(cg, viewSize: arView.bounds.size,
                                        excluding: region.count == 4 ? region : [],
                                        skipTop: isOutdoors ? 0.15 : 0)
        }

        guard let t = reference, frame.count >= 2 else { return nil }
        let f = Self.median(frame)
        guard Self.luma(t) > 0.02, Self.luma(f) > 0.005 else { return nil }
        return (t, f, surroundColor(in: cg, scale: scale, opening: o))
    }

    /// The trim's own color: the median of a ring of points just past the
    /// hardware (or just outside the opening, for an inside mount).
    private func surroundColor(in cg: CGImage, scale: CGFloat, opening o: Opening) -> SIMD3<Float>? {
        let reach = ScreenDoorEntity.reach(for: config)
        let inside = config.mount == .inside
        let hw = o.width / 2
        let hh = o.height / 2
        var points: [SIMD3<Float>] = []
        for gap: Float in [0.03, 0.06] {
            for t: Float in [-0.6, 0, 0.6] {
                points.append(o.center - o.right * (hw + (inside ? 0 : reach.left) + gap) + o.up * (t * hh))
                points.append(o.center + o.right * (hw + (inside ? 0 : reach.right) + gap) + o.up * (t * hh))
                points.append(o.center + o.up * (hh + (inside ? 0 : reach.top) + gap) + o.right * (t * hw))
            }
        }
        let bounds = arView.bounds.insetBy(dx: 8, dy: 8)
        let seen: [SIMD3<Float>] = points.compactMap { point in
            guard let screen = arView.project(point), bounds.contains(screen) else { return nil }
            return Self.averageLinear(cg, at: CGPoint(x: screen.x * scale, y: screen.y * scale))
        }
        return seen.count >= 4 ? Self.median(seen) : nil
    }

    /// True when the camera's exposure says the phone is outdoors in daylight.
    var isOutdoors: Bool {
        guard let frame = arView.session.currentFrame else { return false }
        let intensity = frame.lightEstimate?.ambientIntensity ?? 0
        return frame.camera.exposureDuration < 1.0 / 400 || intensity > 2000
    }

    /// Sets new targets for exposure and color gain. Returns true once the
    /// frame is within about 4% of the reference (or within `deadband` stops,
    /// in which case nothing changes).
    ///
    /// Automatic matching keeps the color correction gentle (the brightest
    /// neutral surface may be off-white) and won't darken the frame by more
    /// than half a stop (a scene with no white in it shouldn't turn white
    /// paint grey). A white the user picked by hand is matched fully.
    private func applyWhiteCorrection(trim: SIMD3<Float>, frame: SIMD3<Float>, deadband: Float = 0,
                                      picked: Bool = false) -> Bool {
        let ratio = Self.luma(trim) / Self.luma(frame)
        let trimChroma = trim / Self.luma(trim)
        let frameChroma = frame / Self.luma(frame)
        let chromaRatio = trimChroma / frameChroma
        let chromaOff = max(abs(log2(chromaRatio.x)), abs(log2(chromaRatio.y)), abs(log2(chromaRatio.z)))
        if deadband > 0, abs(log2(ratio)) < deadband, chromaOff < deadband { return true }

        let step = min(max(log2(ratio), -1), 1)
        let lowest: Float = picked ? -1.5 : -0.5
        matchedExposure = min(max(matchedExposure + step * 0.85, lowest), 2.5)
        let strength: Float = picked ? 0.8 : 0.5
        var gain = colorGain * SIMD3<Float>(
            pow(chromaRatio.x, strength), pow(chromaRatio.y, strength), pow(chromaRatio.z, strength))
        gain /= max(gain.x, max(gain.y, gain.z))
        let floor: Float = picked ? 0.75 : 0.88
        colorGain = gain.clamped(lowerBound: SIMD3(repeating: floor), upperBound: SIMD3(repeating: 1))
        applyExposure()
        return abs(log2(ratio)) < 0.06
    }

    // MARK: - Pixel helpers

    static func luma(_ c: SIMD3<Float>) -> Float {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }

    /// The scene's white: the average of the brightest neutral samples of a
    /// reduced copy of the image, outside `region` (a view-space polygon) and
    /// below the top `skipTop` of the view. Clipped pixels (sky, lamps,
    /// glare) are left out, since their true color is unknown.
    static func sceneWhite(_ image: CGImage, viewSize: CGSize, excluding region: [CGPoint],
                           skipTop: CGFloat) -> SIMD3<Float>? {
        let width = 54
        let height = max(1, Int((CGFloat(width) * CGFloat(image.height) / CGFloat(max(image.width, 1))).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, viewSize.width > 0, viewSize.height > 0 else { return nil }

        let excluded: CGPath? = region.count >= 3 ? {
            let path = CGMutablePath()
            path.addLines(between: region)
            path.closeSubpath()
            return path
        }() : nil

        var samples: [SIMD3<Float>] = []
        samples.reserveCapacity(width * height)
        for y in 0..<height {
            // Row 0 of the bitmap is the top of the image.
            let viewY = (CGFloat(y) + 0.5) / CGFloat(height) * viewSize.height
            if viewY < skipTop * viewSize.height { continue }
            for x in 0..<width {
                let viewX = (CGFloat(x) + 0.5) / CGFloat(width) * viewSize.width
                if let excluded, excluded.contains(CGPoint(x: viewX, y: viewY)) { continue }
                let i = (y * width + x) * 4
                let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
                if max(r, max(g, b)) >= 250 { continue }
                samples.append(SIMD3(srgbToLinear(r), srgbToLinear(g), srgbToLinear(b)))
            }
        }
        guard samples.count >= 40 else { return nil }
        return mean(whitest(samples, fraction: 0.06))
    }

    /// The samples closest to white: bright and neutral.
    static func whitest(_ samples: [SIMD3<Float>], fraction: Float) -> [SIMD3<Float>] {
        func whiteness(_ c: SIMD3<Float>) -> Float {
            let high = max(c.x, max(c.y, c.z))
            let low = min(c.x, min(c.y, c.z))
            let spread = high > 1e-4 ? (high - low) / high : 1
            return luma(c) * max(0, 1 - spread)
        }
        let ranked = samples.sorted { whiteness($0) > whiteness($1) }
        let keep = max(3, Int(Float(ranked.count) * fraction))
        return Array(ranked.prefix(keep))
    }

    /// `color` as it would look if `white` (seen in the same picture) were
    /// Classic White: the light's tint drops out, and brightness is measured
    /// against the room's white rather than the camera's exposure, so white
    /// trim in shadow stays white while grey still reads grey.
    static func relative(_ color: SIMD3<Float>, to white: SIMD3<Float>) -> SIMD3<Float> {
        let tint = pointwiseMax(white, SIMD3(repeating: 0.0001)) / max(luma(white), 0.0001)
        let corrected = color / tint
        let brightness = min(luma(color) / max(luma(white), 0.0001), 1)
        // 0.88: Classic White's brightness, in linear light.
        return corrected * (0.88 * brightness / max(luma(corrected), 0.0001))
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
