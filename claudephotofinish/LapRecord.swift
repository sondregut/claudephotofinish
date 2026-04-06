import Foundation
import UIKit

struct LapRecord: Identifiable {
    let id: UUID
    let crossingNumber: Int
    let time: TimeInterval
    let thumbnailData: Data?
    let gateY: Int
    let componentBounds: CGRect
    let interpolationFraction: Double
    let dBefore: Float
    let dAfter: Float
    let direction: String           // "L>R" or "R>L"
    let usedPreviousFrame: Bool
}
