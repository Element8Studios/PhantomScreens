import CoreGraphics
import CoreVideo
import Vision

/// Finds the most prominent rectangle (a door or window frame) in a camera frame.
enum OpeningDetector {
    /// Candidate rectangles, best first, each as four corners in normalized
    /// image coordinates with a top-left origin, in the camera's native
    /// (landscape) orientation.
    static func detect(in pixelBuffer: CVPixelBuffer) -> [[CGPoint]] {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.15
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.12
        request.quadratureTolerance = 30
        request.minimumConfidence = 0.45
        request.maximumObservations = 6

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        // Prefer large rectangles near the middle of the frame.
        let ranked = (request.results ?? []).sorted { score($0) > score($1) }
        // Vision uses a bottom-left origin; flip to top-left.
        return ranked.map { o in
            [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { CGPoint(x: $0.x, y: 1 - $0.y) }
        }
    }

    private static func score(_ o: VNRectangleObservation) -> CGFloat {
        let box = o.boundingBox
        let dx = box.midX - 0.5
        let dy = box.midY - 0.5
        return box.width * box.height * CGFloat(o.confidence) - (dx * dx + dy * dy) * 0.5
    }
}
