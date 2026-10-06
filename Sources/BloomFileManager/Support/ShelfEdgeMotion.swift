import SwiftUI

enum ShelfEdge: String, CaseIterable {
    case top, right, bottom, left

    var isVertical: Bool { self == .left || self == .right }
    var title: String { rawValue.capitalized }
    var collapseSymbol: String {
        switch self {
        case .top: "chevron.up"
        case .right: "chevron.right"
        case .bottom: "chevron.down"
        case .left: "chevron.left"
        }
    }
    var alignment: Alignment {
        switch self {
        case .top: .top
        case .right: .trailing
        case .bottom: .bottom
        case .left: .leading
        }
    }
    var outward: CGSize {
        switch self {
        case .top: CGSize(width: 0, height: -1)
        case .right: CGSize(width: 1, height: 0)
        case .bottom: CGSize(width: 0, height: 1)
        case .left: CGSize(width: -1, height: 0)
        }
    }
}

// A single clockwise coordinate keeps a carried notch continuous at screen corners.
// PenguinNotch's border-following interaction is the reference; drawing uses a native Path.
struct ShelfBorderTrack {
    let frame: CGRect
    var perimeter: CGFloat { 2 * (frame.width + frame.height) }
    enum Reading: Equatable { case edge(ShelfEdge), corner(Int) }

    func wrapped(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, perimeter.isFinite, perimeter > 0 else { return 0 }
        let result = value.truncatingRemainder(dividingBy: perimeter)
        return result < 0 ? result + perimeter : result
    }

    func gap(from: CGFloat, to: CGFloat) -> CGFloat {
        let distance = wrapped(to - from)
        return distance > perimeter / 2 ? distance - perimeter : distance
    }

    func distance(to edge: ShelfEdge, from point: CGPoint) -> CGFloat {
        switch edge {
        case .top: max(0, frame.maxY - point.y)
        case .right: max(0, frame.maxX - point.x)
        case .bottom: max(0, point.y - frame.minY)
        case .left: max(0, point.x - frame.minX)
        }
    }

    func nearest(to point: CGPoint, keeping current: ShelfEdge) -> ShelfEdge {
        let nearest = ShelfEdge.allCases.min { distance(to: $0, from: point) < distance(to: $1, from: point) } ?? current
        return distance(to: nearest, from: point) + 24 < distance(to: current, from: point) ? nearest : current
    }

    func coordinate(of point: CGPoint, on edge: ShelfEdge) -> CGFloat {
        let x = min(max(point.x - frame.minX, 0), frame.width)
        let y = min(max(frame.maxY - point.y, 0), frame.height)
        switch edge {
        case .top: return x
        case .right: return frame.width + y
        case .bottom: return 2 * frame.width + frame.height - x
        case .left: return wrapped(perimeter - y)
        }
    }

    func location(at coordinate: CGFloat) -> (edge: ShelfEdge, point: CGPoint) {
        let value = wrapped(coordinate), width = frame.width, height = frame.height
        if value < width { return (.top, CGPoint(x: frame.minX + value, y: frame.maxY)) }
        if value < width + height { return (.right, CGPoint(x: frame.maxX, y: frame.maxY - value + width)) }
        if value < 2 * width + height { return (.bottom, CGPoint(x: frame.maxX - value + width + height, y: frame.minY)) }
        return (.left, CGPoint(x: frame.minX, y: frame.minY + value - 2 * width - height))
    }

    private var corners: [(CGFloat, ShelfEdge, ShelfEdge)] {
        [(frame.width, .top, .right), (frame.width + frame.height, .right, .bottom),
         (2 * frame.width + frame.height, .bottom, .left), (0, .left, .top)]
    }

    func reading(at point: CGPoint, edge: ShelfEdge) -> Reading {
        for (index, corner) in corners.enumerated() {
            if distance(to: corner.1, from: point) < 160 && distance(to: corner.2, from: point) < 160 {
                return .corner(index)
            }
        }
        return .edge(edge)
    }

    func coordinate(of point: CGPoint, reading: Reading) -> CGFloat {
        switch reading {
        case .edge(let edge): coordinate(of: point, on: edge)
        case .corner(let index):
            wrapped(corners[index].0 + distance(to: corners[index].1, from: point) - distance(to: corners[index].2, from: point))
        }
    }

    func notchLanding(at coordinate: CGFloat, notch: CGRect?) -> CGFloat? {
        guard let notch else { return nil }
        let place = location(at: coordinate)
        guard place.edge == .top, abs(place.point.x - notch.midX) <= notch.width / 2 + 80 else { return nil }
        return self.coordinate(of: CGPoint(x: notch.midX, y: frame.maxY), on: .top)
    }
}

struct ShelfCarryMotion {
    let track: ShelfBorderTrack
    let screenID: Int
    var position: CGFloat
    var target: CGFloat
    var velocity: CGFloat = 0
    var grip: CGFloat
    var reading: ShelfBorderTrack.Reading
    var pointerEdge: ShelfEdge
    var isSettling = false
    var docksToHardware = false

    mutating func follow(_ point: CGPoint) {
        guard !isSettling, point.x.isFinite, point.y.isFinite else { return }
        let edge = track.nearest(to: point, keeping: pointerEdge)
        let nextReading = track.reading(at: point, edge: edge)
        if nextReading != reading {
            grip += track.gap(from: track.coordinate(of: point, reading: nextReading),
                              to: track.coordinate(of: point, reading: reading))
        }
        pointerEdge = edge
        reading = nextReading
        target = track.wrapped(track.coordinate(of: point, reading: reading) + grip)
    }

    mutating func advance(elapsed: TimeInterval, reduceMotion: Bool) -> Bool {
        guard elapsed.isFinite, elapsed > 0 else { return false }
        let gap = track.gap(from: position, to: target)
        if reduceMotion || (abs(gap) < 0.3 && abs(velocity) < 6) {
            position = target
            velocity = 0
            return isSettling
        }
        var moved = 0.0, speed = Double(velocity)
        Spring(response: isSettling ? 0.3 : 0.2, dampingRatio: isSettling ? 0.74 : 0.84)
            .update(value: &moved, velocity: &speed, target: Double(gap), deltaTime: min(elapsed, 1.0 / 30))
        position = track.wrapped(position + CGFloat(moved))
        velocity = CGFloat(speed)
        return false
    }
}
