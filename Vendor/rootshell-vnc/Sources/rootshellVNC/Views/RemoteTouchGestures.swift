import CoreGraphics
import Foundation

/// A remote mouse button, in standard RFB bit order.
public enum RemotePointerButton: Sendable, Hashable, CaseIterable {
    case left
    case middle
    case right

    public var mask: UInt8 {
        switch self {
        case .left: TouchInputHandler.leftButton
        case .middle: TouchInputHandler.middleButton
        case .right: TouchInputHandler.rightButton
        }
    }
}

/// What a three-finger swipe sends to the remote computer.
public enum RemoteSwipeAction: String, CaseIterable, Hashable, Sendable {
    case none
    case missionControl
    case applicationWindows
    case moveLeftASpace
    case moveRightASpace

    var command: RemoteCommand? {
        switch self {
        case .none: nil
        case .missionControl: .missionControl
        case .applicationWindows: .applicationWindows
        case .moveLeftASpace: .moveLeftASpace
        case .moveRightASpace: .moveRightASpace
        }
    }
}

enum RemoteSwipeDirection: Equatable, Sendable {
    case up, down, left, right
}

/// The edges reached by a deliberate inward stroke on the touch surface.
struct RemoteTouchEdges: OptionSet, Sendable {
    let rawValue: UInt8
    static let left = Self(rawValue: 1), right = Self(rawValue: 2)
    static let top = Self(rawValue: 4), bottom = Self(rawValue: 8)

    static func at(_ point: CGPoint, in size: CGSize) -> Self {
        let bounds = CGRect(origin: .zero, size: size)
        guard bounds.contains(point) else { return [] }
        let margin = min(24, min(size.width, size.height) / 8)
        var edges = Self()
        if point.x < margin { edges.insert(.left) }
        else if size.width - point.x <= margin { edges.insert(.right) }
        if point.y < margin { edges.insert(.top) }
        else if size.height - point.y <= margin { edges.insert(.bottom) }
        return edges
    }

    func inward(along movement: CGPoint) -> Self {
        let x = movement.x, y = movement.y
        let horizontal: Self = x > 0 ? .left : .right
        let vertical: Self = y > 0 ? .top : .bottom
        if contains(horizontal), contains(vertical), min(abs(x), abs(y)) * 2 >= max(abs(x), abs(y)) {
            return [horizontal, vertical]
        }
        if contains(horizontal), abs(x) >= abs(y) * 1.4 { return horizontal }
        if contains(vertical), abs(y) >= abs(x) * 1.4 { return vertical }
        return []
    }

    func destination(from anchor: CGPoint, framebuffer: CGSize) -> CGPoint {
        let maxX = max(0, framebuffer.width - 1), maxY = max(0, framebuffer.height - 1)
        var point = CGPoint(x: min(maxX, max(0, anchor.x)), y: min(maxY, max(0, anchor.y)))
        if contains(.left) { point.x = 0 } else if contains(.right) { point.x = maxX }
        if contains(.top) { point.y = 0 } else if contains(.bottom) { point.y = maxY }
        return point
    }
}

public enum RemoteSwipeFingers: Int, CaseIterable, Sendable { case off = 0, three = 3, four = 4 }

public enum RemotePencilAction: String, CaseIterable, Sendable {
    case none, secondaryClick, middleClick, toggleToolbar, toggleExpandedToolbar
}

public enum RemoteScrollSpeed: Int, Codable, Sendable, CaseIterable {
    case slow = 50
    case moderatelySlow = 75
    case standard = 100
    case moderatelyFast = 150
    case fast = 200

    public var multiplier: CGFloat { CGFloat(rawValue) / 100 }
}

extension ScrollPointAccumulator {
    mutating func consume(_ delta: CGPoint, speed: RemoteScrollSpeed) -> (x: Int32, y: Int32) {
        consume(deltaX: delta.x * speed.multiplier, deltaY: delta.y * speed.multiplier)
    }
}

/// Touch gesture options a host app can change: the hold delay, the
/// three-finger swipe mappings, and the held-button label.
public struct RemoteTouchGestureConfiguration: Equatable, Sendable {
    public static let defaultHoldDuration: TimeInterval = 0.3
    public static let holdDurationRange: ClosedRange<TimeInterval> = 0.15...1.0

    /// How long still fingers rest before they hold a button down.
    public var holdDuration: TimeInterval
    public var swipeUp: RemoteSwipeAction
    public var swipeDown: RemoteSwipeAction
    public var swipeLeft: RemoteSwipeAction
    public var swipeRight: RemoteSwipeAction
    public var upFingers: RemoteSwipeFingers = .three
    public var downFingers: RemoteSwipeFingers = .three
    public var horizontalFingers: RemoteSwipeFingers = .three
    public var pencilDoubleTap: RemotePencilAction = .secondaryClick
    public var pencilSqueeze: RemotePencilAction = .none
    public var togglesToolbarWithTwoFingerDoubleTap = false
    public var allowsMomentumScrolling = true
    public var scrollSpeed: RemoteScrollSpeed = .standard
    /// Labels the button a touch hold is pressing while it is down.
    public var showsButtonIndicator: Bool

    /// Swipe defaults follow a Mac trackpad, where content follows the
    /// fingers: swiping left moves to the Space on the right.
    public init(
        holdDuration: TimeInterval = Self.defaultHoldDuration,
        swipeUp: RemoteSwipeAction = .missionControl,
        swipeDown: RemoteSwipeAction = .applicationWindows,
        swipeLeft: RemoteSwipeAction = .moveRightASpace,
        swipeRight: RemoteSwipeAction = .moveLeftASpace,
        showsButtonIndicator: Bool = true
    ) {
        self.holdDuration = holdDuration
        self.swipeUp = swipeUp
        self.swipeDown = swipeDown
        self.swipeLeft = swipeLeft
        self.swipeRight = swipeRight
        self.showsButtonIndicator = showsButtonIndicator
    }

    public static let standard = Self()

    public var resolvedHoldDuration: TimeInterval {
        guard holdDuration.isFinite else { return Self.defaultHoldDuration }
        return min(
            Self.holdDurationRange.upperBound,
            max(Self.holdDurationRange.lowerBound, holdDuration))
    }

    var activeFingerCounts: [Int] {
        [(swipeUp, upFingers), (swipeDown, downFingers), (swipeLeft, horizontalFingers), (swipeRight, horizontalFingers)]
            .compactMap { action, fingers in action == .none || fingers == .off ? nil : fingers.rawValue }
    }

    func accepts(_ fingers: Int, for direction: RemoteSwipeDirection) -> Bool {
        let setting: RemoteSwipeFingers = switch direction {
        case .up: upFingers
        case .down: downFingers
        case .left, .right: horizontalFingers
        }
        return setting != .off && setting.rawValue == fingers
    }

    func action(for direction: RemoteSwipeDirection) -> RemoteSwipeAction {
        switch direction {
        case .up: swipeUp
        case .down: swipeDown
        case .left: swipeLeft
        case .right: swipeRight
        }
    }
}

/// Turns one multi-finger stroke into at most one swipe. A long stroke fires
/// as soon as it is clearly along one axis; a short one fires at release only
/// if it was quick.
struct MultiFingerSwipeTracker: Equatable, Sendable {
    static let commitDistance: CGFloat = 60
    static let flickDistance: CGFloat = 24
    static let flickSpeed: CGFloat = 400
    /// How much longer the main axis must be than the other one.
    static let dominance: CGFloat = 1.5

    private(set) var hasFired = false

    mutating func update(translation: CGPoint) -> RemoteSwipeDirection? {
        guard !hasFired,
              let direction = Self.direction(of: translation, minimum: Self.commitDistance)
        else { return nil }
        hasFired = true
        return direction
    }

    mutating func end(translation: CGPoint, velocity: CGPoint) -> RemoteSwipeDirection? {
        guard !hasFired,
              let direction = Self.direction(of: translation, minimum: Self.flickDistance),
              let speedDirection = Self.direction(of: velocity, minimum: Self.flickSpeed),
              speedDirection == direction else { return nil }
        hasFired = true
        return direction
    }

    mutating func reset() {
        hasFired = false
    }

    static func direction(of vector: CGPoint, minimum: CGFloat) -> RemoteSwipeDirection? {
        guard vector.x.isFinite, vector.y.isFinite else { return nil }
        let horizontal = abs(vector.x)
        let vertical = abs(vector.y)
        if horizontal >= minimum, horizontal >= vertical * dominance {
            return vector.x < 0 ? .left : .right
        }
        if vertical >= minimum, vertical >= horizontal * dominance {
            return vector.y < 0 ? .up : .down
        }
        return nil
    }
}

extension VNCKeyboardModifiers {
    /// Mac menu glyphs in menu order: ⌃⌥⇧⌘.
    var symbols: String {
        var symbols = ""
        if contains(.control) { symbols += "⌃" }
        if contains(.option) { symbols += "⌥" }
        if contains(.shift) { symbols += "⇧" }
        if contains(.command) { symbols += "⌘" }
        return symbols
    }

    /// PC key legends in the usual order: Ctrl, Alt, Shift, Win.
    var keyNames: [String] {
        var names: [String] = []
        if contains(.control) { names.append("Ctrl") }
        if contains(.option) { names.append("Alt") }
        if contains(.shift) { names.append("Shift") }
        if contains(.command) { names.append("Win") }
        return names
    }
}

enum TouchButtonIndicatorText {
    static func title(for button: RemotePointerButton, modifiers: VNCKeyboardModifiers) -> String {
        let name = switch button {
        case .left:
            String(localized: "Left Button", bundle: .module, comment: "Label shown while a touch hold presses the remote mouse button")
        case .middle:
            String(localized: "Middle Button", bundle: .module, comment: "Label shown while a touch hold presses the remote mouse button")
        case .right:
            String(localized: "Right Button", bundle: .module, comment: "Label shown while a touch hold presses the remote mouse button")
        }
        let symbols = modifiers.symbols
        return symbols.isEmpty ? name : "\(symbols) \(name)"
    }
}
