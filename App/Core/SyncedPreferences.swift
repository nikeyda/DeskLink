import Foundation
import rootshellVNC

enum PreferenceValue: Codable, Sendable, Equatable {
    case flag(Bool)
    case number(Int)
    case speed(Double)
    case text(String)
}

/// Settings exchanged in the user-selected library folder. Authentication, trust and device permissions stay local.
enum SyncedPreference: String, CaseIterable {
    case list = "library.listLayout"
    case savedOrder = "library.savedOrder"
    case favoriteOrder = "library.favoriteOrder"
    case recentOrder = "library.recentOrder"
    case reconnect = "connection.reconnect"
    case cursor = "connection.clientCursor"
    case speed = "pointer.speed"
    case up = "gesture.upFingers"
    case down = "gesture.downFingers"
    case horizontal = "gesture.horizontalFingers"
    case holdDuration = "gesture.holdDuration"
    case keyRepeat = "keyboard.repeat"
    case keyDelay = "keyboard.delay"
    case keyInterval = "keyboard.interval"
    case style = "toolbar.style"
    case size = "toolbar.size"
    case buttons = "toolbar.buttons"
    case keyboardTrailing = "toolbar.keyboardTrailing"
    case twoFingerToggle = "toolbar.twoFingerToggle"
    case doubleTap = "pencil.doubleTap"
    case squeeze = "pencil.squeeze"

    static func snapshot(_ defaults: UserDefaults) -> [String: PreferenceValue] {
        Dictionary(uniqueKeysWithValues: allCases.compactMap { field in
            field.value(in: defaults).map { (field.rawValue, $0) }
        })
    }

    static func apply(_ values: [String: PreferenceValue], to defaults: UserDefaults) {
        for field in allCases {
            let wanted = values[field.rawValue]
            if let wanted, !field.accepts(wanted) { continue }
            guard wanted != field.value(in: defaults) else { continue }
            switch wanted {
            case .flag(let selected): defaults.set(selected, forKey: field.rawValue)
            case .number(let count): defaults.set(count, forKey: field.rawValue)
            case .speed(let speed): defaults.set(speed, forKey: field.rawValue)
            case .text(let text): defaults.set(text, forKey: field.rawValue)
            case nil: defaults.removeObject(forKey: field.rawValue)
            }
        }
    }

    func accepts(_ value: PreferenceValue) -> Bool {
        switch (self, value) {
        case (.list, .flag), (.reconnect, .flag), (.cursor, .flag), (.keyboardTrailing, .flag), (.twoFingerToggle, .flag), (.keyRepeat, .flag):
            true
        case (.speed, .speed(let value)): (0.5...3).contains(value)
        case (.holdDuration, .speed(let value)): RemoteTouchGestureConfiguration.holdDurationRange.contains(value)
        case (.keyDelay, .speed(let value)): VNCKeyRepeat.delayRange.contains(value)
        case (.keyInterval, .speed(let value)): VNCKeyRepeat.intervalRange.contains(value)
        case (.up, .number(let n)), (.down, .number(let n)), (.horizontal, .number(let n)): [0, 3, 4].contains(n)
        case (.style, .text(let text)): ["docked", "floating", "carousel"].contains(text)
        case (.savedOrder, .text(let text)), (.favoriteOrder, .text(let text)): ComputerOrder(rawValue: text) != nil
        case (.recentOrder, .text(let text)): ComputerOrder(rawValue: text).map { $0 != .manual } == true
        case (.size, .text(let text)): ["small", "standard", "large", "extraLarge"].contains(text)
        case (.doubleTap, .text(let text)), (.squeeze, .text(let text)):
            ["none", "secondaryClick", "middleClick", "toggleToolbar", "toggleExpandedToolbar"].contains(text)
        case (.buttons, .text): true
        default: false
        }
    }

    private func value(in defaults: UserDefaults) -> PreferenceValue? {
        guard defaults.object(forKey: rawValue) != nil else { return nil }
        let result: PreferenceValue?
        switch self {
        case .list, .reconnect, .cursor, .keyboardTrailing, .twoFingerToggle, .keyRepeat: result = .flag(defaults.bool(forKey: rawValue))
        case .speed, .holdDuration, .keyDelay, .keyInterval: result = .speed(defaults.double(forKey: rawValue))
        case .up, .down, .horizontal: result = .number(defaults.integer(forKey: rawValue))
        case .style, .size, .buttons, .doubleTap, .squeeze, .savedOrder, .favoriteOrder, .recentOrder:
            result = defaults.string(forKey: rawValue).map(PreferenceValue.text)
        }
        return result.flatMap { accepts($0) ? $0 : nil }
    }
}
