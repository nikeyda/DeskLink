#if !targetEnvironment(macCatalyst)
import SwiftUI

enum ToolbarProfileDevice: String, CaseIterable {
    case iPhone, iPad

    @MainActor static var current: Self {
        DisplayClient.current == .iPhone ? .iPhone : .iPad
    }

    var styleKey: SyncedPreference { self == .iPhone ? .phoneToolbarStyle : .padToolbarStyle }
    var sizeKey: SyncedPreference { self == .iPhone ? .phoneToolbarSize : .padToolbarSize }
    var buttonsKey: SyncedPreference { self == .iPhone ? .phoneToolbarButtons : .padToolbarButtons }
    var keyboardKey: SyncedPreference { self == .iPhone ? .phoneToolbarKeyboardTrailing : .padToolbarKeyboardTrailing }
}

struct ToolbarProfile: DynamicProperty {
    @AppStorage private var legacyStyle: DeskToolbarStyle
    @AppStorage private var legacySize: DeskToolbarSize
    @AppStorage private var legacyButtons: String
    @AppStorage private var legacyKeyboardTrailing: Bool
    @AppStorage private var deviceStyle: DeskToolbarStyle?
    @AppStorage private var deviceSize: DeskToolbarSize?
    @AppStorage private var deviceButtons: String?
    @AppStorage private var deviceKeyboardTrailing: Bool?

    init(device: ToolbarProfileDevice, store: UserDefaults? = nil) {
        _legacyStyle = AppStorage(wrappedValue: .docked, SyncedPreference.style.rawValue, store: store)
        _legacySize = AppStorage(wrappedValue: .standard, SyncedPreference.size.rawValue, store: store)
        _legacyButtons = AppStorage(wrappedValue: DeskToolbarButton.standard, SyncedPreference.buttons.rawValue, store: store)
        _legacyKeyboardTrailing = AppStorage(wrappedValue: false, SyncedPreference.keyboardTrailing.rawValue, store: store)
        _deviceStyle = AppStorage(device.styleKey.rawValue, store: store)
        _deviceSize = AppStorage(device.sizeKey.rawValue, store: store)
        _deviceButtons = AppStorage(device.buttonsKey.rawValue, store: store)
        _deviceKeyboardTrailing = AppStorage(device.keyboardKey.rawValue, store: store)
    }

    // Leave the old shared values as a fallback. Older synced libraries can
    // still supply them without writing over an edited device's settings.
    var style: DeskToolbarStyle {
        get { deviceStyle ?? legacyStyle }
        nonmutating set { deviceStyle = newValue }
    }

    var size: DeskToolbarSize {
        get { deviceSize ?? legacySize }
        nonmutating set { deviceSize = newValue }
    }

    var buttons: String {
        get { deviceButtons ?? legacyButtons }
        nonmutating set { deviceButtons = newValue }
    }

    var keyboardTrailing: Bool {
        get { deviceKeyboardTrailing ?? legacyKeyboardTrailing }
        nonmutating set { deviceKeyboardTrailing = newValue }
    }
}
#endif
