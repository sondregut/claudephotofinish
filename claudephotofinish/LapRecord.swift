import Foundation
import UIKit

struct LapRecord: Identifiable {
    let id: UUID
    let crossingNumber: Int
    let time: TimeInterval
    let thumbnailData: Data?
    let gateY: Int                  // §19 torsoGateY — drives the dot and timing
    let rawGateY: Int               // §19 analyzeGate picker output — debug only
    let triggerHRun: Int            // §19 hRun at the torso row
    let triggerBandRows: Int        // §19 rows in 7-row window meeting torsoMinHRun
    let componentBounds: CGRect
    let interpolationFraction: Double
    let dBefore: Float
    let dAfter: Float
    let direction: String           // "L>R" or "R>L"
    let usedPreviousFrame: Bool
    /// True if this lap was captured on the front camera. Front-camera
    /// thumbnails are horizontally mirrored relative to the processing
    /// buffer (rot90CW vs pure transpose), so X-axis overlays and tap
    /// conversions need to apply the inverse flip to stay aligned with
    /// the algorithm's processing-space X.
    let isFrontCamera: Bool
    /// User's ground-truth mark in source 180x320 coordinate space
    /// (same coordinate system as gateY and the algorithm's dB/dA).
    /// For front-camera laps, the X is already mirror-corrected at
    /// store time, so it can be compared directly to gateColumn ± dB/dA.
    /// Nil until the user taps the fullscreen thumbnail.
    var userMarkedPoint: CGPoint?
}
