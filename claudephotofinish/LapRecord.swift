import Foundation
import UIKit

struct LapRecord: Identifiable {
    let id: UUID
    let crossingNumber: Int
    let time: TimeInterval
    let thumbnailData: Data?
    let gateY: Int
    let componentBounds: CGRect
}
