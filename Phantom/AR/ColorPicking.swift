import ARKit
import UIKit

/// What the centre-screen colour picker is for.
enum PickerPurpose: Equatable {
    /// Aim at the trim; the rendered white is matched to it.
    case whiteBalance
    /// Aim at the trim; its colour becomes the custom frame colour.
    case customColor
}

extension PhantomSession {
    func beginPicking(_ purpose: PickerPurpose) {
        guard stage == .placed else { return }
        setAdjusting(false)
        live.picker.color = nil
        pickerPurpose = purpose
    }

    func cancelPicking() {
        pickerPurpose = nil
        live.picker.color = nil
    }

    /// Uses the colour under the reticle.
    func confirmPicking() {
        guard let purpose = pickerPurpose else { return }
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        switch purpose {
        case .whiteBalance:
            matchWhiteToTrim(trimPoint: center)
        case .customColor:
            guard let color = live.picker.color else { return }
            var newConfig = config
            newConfig.finish = .custom
            newConfig.customColorHex = color.hexString
            newConfig.customMatchedToTrim = true
            config = newConfig
            showToast("Frame color set to \(color.hexString). Your expert color-matches it on site.", duration: 3)
        }
        pickerPurpose = nil
        live.picker.color = nil
    }

    /// Called from the frame loop while picking: samples the camera at the centre.
    func updatePickedColor() {
        guard pickerPurpose != nil,
              Date().timeIntervalSince(lastPickSample) > 0.12,
              let frame = arView.session.currentFrame else { return }
        lastPickSample = Date()
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        live.picker.color = cameraColor(at: center, in: frame)
    }

    /// Average sRGB colour of a small patch of the camera image at a view point.
    func cameraColor(at point: CGPoint, in frame: ARFrame) -> UIColor? {
        let buffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(buffer) >= 2 else { return nil }
        let size = arView.bounds.size
        let toImage = frame.displayTransform(for: .portrait, viewportSize: size).inverted()
        let normalized = CGPoint(x: point.x / size.width, y: point.y / size.height).applying(toImage)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cx = Int(normalized.x * CGFloat(width))
        let cy = Int(normalized.y * CGFloat(height))

        var sum = SIMD3<Float>.zero
        var count: Float = 0
        for y in stride(from: cy - 6, through: cy + 6, by: 2) {
            for x in stride(from: cx - 6, through: cx + 6, by: 2) {
                guard x >= 0, y >= 0, x < width - 1, y < height - 1 else { continue }
                let luma = Float(yBase.advanced(by: y * yRow).assumingMemoryBound(to: UInt8.self)[x]) / 255
                let chroma = cBase.advanced(by: (y / 2) * cRow).assumingMemoryBound(to: UInt8.self)
                let cb = Float(chroma[(x / 2) * 2]) / 255 - 0.5
                let cr = Float(chroma[(x / 2) * 2 + 1]) / 255 - 0.5
                // BT.601 full range, as used for ARKit's captured image.
                sum += SIMD3(luma + 1.402 * cr,
                             luma - 0.344136 * cb - 0.714136 * cr,
                             luma + 1.772 * cb)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let rgb = (sum / count).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
        return UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
    }
}
