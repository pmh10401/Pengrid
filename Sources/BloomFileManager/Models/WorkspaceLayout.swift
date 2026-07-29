import Foundation

enum WorkspaceSplitRatio {
    static let bounds = 0.25...0.75

    static func clamped(_ ratio: Double) -> Double {
        if ratio.isNaN { return 0.5 }
        if ratio <= bounds.lowerBound { return bounds.lowerBound }
        if ratio >= bounds.upperBound { return bounds.upperBound }
        return ratio
    }
}
