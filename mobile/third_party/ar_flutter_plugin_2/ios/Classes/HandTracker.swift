import ARKit
import UIKit
import Vision

/// Patch 6: runs Vision hand-pose detection on ARKit camera frames and reports a
/// distilled gesture payload (per hand: pinch ratio + pinch midpoint in
/// view-normalized coordinates), mirroring the Android HandTracker contract.
@available(iOS 14.0, *)
class HandTracker {
    private let onGesture: ([String: Any]) -> Void
    private let queue = DispatchQueue(label: "hand-tracking", qos: .userInitiated)
    private var isProcessing = false
    private var lastSubmitTime: CFTimeInterval = 0
    private let minInterval: CFTimeInterval = 0.066 // ~15 Hz
    private let request: VNDetectHumanHandPoseRequest

    /// Joint order matching MediaPipe hand-landmark indices 0-20, so the Dart
    /// overlay can use one set of skeleton connections for both platforms.
    private static let jointOrder: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    init(onGesture: @escaping ([String: Any]) -> Void) {
        self.onGesture = onGesture
        request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
    }

    func maybeDetect(frame: ARFrame, viewportSize: CGSize, orientation: UIInterfaceOrientation) {
        let now = CACurrentMediaTime()
        guard !isProcessing, now - lastSubmitTime >= minInterval,
              viewportSize.width > 0, viewportSize.height > 0 else { return }
        isProcessing = true
        lastSubmitTime = now

        // Maps normalized capture-image coordinates to normalized view
        // coordinates, folding in rotation and aspect-fill crop (this is the
        // ARKit analogue of ARCore's Frame.transformCoordinates2d).
        let displayTransform = frame.displayTransform(for: orientation, viewportSize: viewportSize)
        let pixelBuffer = frame.capturedImage
        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)
        let imageAspect = imageHeight > 0 ? CGFloat(imageWidth) / CGFloat(imageHeight) : 1

        queue.async { [weak self] in
            guard let self = self else { return }
            var hands: [[String: Any]] = []
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
            do {
                try handler.perform([self.request])
                for observation in self.request.results ?? [] {
                    if let hand = self.distill(observation,
                                               displayTransform: displayTransform,
                                               imageAspect: imageAspect) {
                        hands.append(hand)
                        if hands.count == 2 { break }
                    }
                }
            } catch {
                // Detection failure: still report an empty tick so the Dart
                // side's grace-period logic keeps running off data.
            }
            let payload: [String: Any] = [
                "timestampMs": Int(CACurrentMediaTime() * 1000),
                "hands": hands,
            ]
            DispatchQueue.main.async {
                self.onGesture(payload)
            }
            self.isProcessing = false
        }
    }

    private func distill(_ observation: VNHumanHandPoseObservation,
                         displayTransform: CGAffineTransform,
                         imageAspect: CGFloat) -> [String: Any]? {
        guard
            let thumbTip = try? observation.recognizedPoint(.thumbTip),
            let indexTip = try? observation.recognizedPoint(.indexTip),
            let wrist = try? observation.recognizedPoint(.wrist),
            let middleMCP = try? observation.recognizedPoint(.middleMCP),
            thumbTip.confidence > 0.3, indexTip.confidence > 0.3,
            wrist.confidence > 0.3, middleMCP.confidence > 0.3
        else { return nil }

        // Vision points use a bottom-left origin; flip into capture-image UV.
        func toImageUV(_ point: VNRecognizedPoint) -> CGPoint {
            CGPoint(x: point.location.x, y: 1 - point.location.y)
        }

        let thumb = toImageUV(thumbTip)
        let index = toImageUV(indexTip)
        let wristUV = toImageUV(wrist)
        let middle = toImageUV(middleMCP)

        // Aspect-correct x so the ratio is isotropic and matches Android.
        let pinchDistance = hypot((thumb.x - index.x) * imageAspect, thumb.y - index.y)
        let handSize = max(hypot((wristUV.x - middle.x) * imageAspect, wristUV.y - middle.y), 1e-4)

        let midpoint = CGPoint(x: (thumb.x + index.x) / 2, y: (thumb.y + index.y) / 2)
        let viewPoint = midpoint.applying(displayTransform)

        let confidence = min(min(thumbTip.confidence, indexTip.confidence),
                             min(wrist.confidence, middleMCP.confidence))

        // All 21 landmarks in view-normalized coordinates, for the debug
        // overlay. Low-confidence joints are sent as (-1, -1) so the overlay
        // can skip them while keeping MediaPipe-compatible indices.
        let landmarks: [[Double]] = HandTracker.jointOrder.map { joint in
            guard let point = try? observation.recognizedPoint(joint),
                  point.confidence > 0.1 else { return [-1.0, -1.0] }
            let viewPos = CGPoint(x: point.location.x, y: 1 - point.location.y)
                .applying(displayTransform)
            return [Double(viewPos.x), Double(viewPos.y)]
        }

        return [
            "pinchRatio": Double(pinchDistance / handSize),
            "cx": Double(min(max(viewPoint.x, 0), 1)),
            "cy": Double(min(max(viewPoint.y, 0), 1)),
            "confidence": Double(confidence),
            "landmarks": landmarks,
        ]
    }
}
