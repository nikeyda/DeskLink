#if targetEnvironment(macCatalyst)
import Foundation
import UIKit

/// Reads the Mac keyboard layout for keys AppKit keeps from UIKit, whose
/// press therefore carries no characters. HIToolbox has no Catalyst headers.
@MainActor
enum CatalystKeyboardLayout {
    private typealias CopyLayout = @convention(c) () -> Unmanaged<AnyObject>?
    private typealias GetProperty = @convention(c) (AnyObject, CFString) -> UnsafeRawPointer?
    private typealias KeyboardType = @convention(c) () -> UInt8
    private typealias LayoutType = @convention(c) (Int16) -> UInt32
    private typealias Translate = @convention(c) (
        UnsafeRawPointer, UInt16, UInt16, UInt32, UInt32, UInt32,
        UnsafeMutablePointer<UInt32>, Int, UnsafeMutablePointer<Int>, UnsafeMutablePointer<UInt16>
    ) -> Int32

    private struct Symbols {
        let copyLayout: CopyLayout
        let getProperty: GetProperty
        let layoutData: CFString
        let keyboardType: KeyboardType
        let layoutType: LayoutType
        let translate: Translate
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen(
                  "/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/HIToolbox", RTLD_NOW),
              let copyLayout = dlsym(handle, "TISCopyCurrentKeyboardLayoutInputSource"),
              let getProperty = dlsym(handle, "TISGetInputSourceProperty"),
              let layoutData = dlsym(handle, "kTISPropertyUnicodeKeyLayoutData"),
              let keyboardType = dlsym(handle, "LMGetKbdType"),
              let layoutType = dlsym(handle, "KBGetLayoutType"),
              let translate = dlsym(handle, "UCKeyTranslate") else { return nil }
        return Symbols(
            copyLayout: unsafeBitCast(copyLayout, to: CopyLayout.self),
            getProperty: unsafeBitCast(getProperty, to: GetProperty.self),
            layoutData: layoutData.assumingMemoryBound(to: CFString.self).pointee,
            keyboardType: unsafeBitCast(keyboardType, to: KeyboardType.self),
            layoutType: unsafeBitCast(layoutType, to: LayoutType.self),
            translate: unsafeBitCast(translate, to: Translate.self))
    }()

    private struct Layout {
        let data: Data
        let keyboardType: UInt8
        let isISO: Bool

        func keyCode(for usage: UInt32) -> UInt16? {
            switch usage {
            case 0x35 where isISO: 0x0A
            case 0x64 where isISO: 0x32
            default: MacKeyboardPosition.keyCode(for: usage)
            }
        }
    }

    private static var current: Layout? {
        guard let symbols, let source = symbols.copyLayout()?.takeRetainedValue(),
              let property = symbols.getProperty(source, symbols.layoutData) else { return nil }
        let keyboardType = symbols.keyboardType()
        return Layout(data: Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data,
                      keyboardType: keyboardType, isISO: symbols.layoutType(Int16(keyboardType)) == 0x49534F20)
    }

    private static func translate(usage: UInt32, layout: Layout, action: UInt16, modifiers: UInt32,
                                  options: UInt32, state: inout UInt32) -> String? {
        guard let symbols, let code = layout.keyCode(for: usage) else { return nil }
        var length = 0
        var characters = [UInt16](repeating: 0, count: 255)
        let status = layout.data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return Int32(-50) }
            return symbols.translate(base, code, action, modifiers, UInt32(layout.keyboardType), options,
                                     &state, characters.count, &length, &characters)
        }
        guard status == 0 else { return nil }
        return String(decoding: characters.prefix(length), as: UTF16.self)
    }

    /// The unmodified character on the key left of 1, HID usage 0x35.
    static var graveKeyCharacter: String? {
        guard let layout = current else { return nil }
        var state: UInt32 = 0
        return translate(usage: 0x35, layout: layout, action: 3, modifiers: 0, options: 1, state: &state)
    }

    /// Keeps the host layout's dead-key context for one focused remote view.
    @MainActor
    struct LocalOptionInput {
        private var deadKeyState: UInt32 = 0
        private var pendingLayout: Layout?

        mutating func reset() {
            deadKeyState = 0
            pendingLayout = nil
        }

        mutating func cancelPendingAccent() -> Bool {
            guard deadKeyState != 0 else { return false }
            reset()
            return true
        }

        mutating func route(usage: UInt32, unmodified: String, flags: UIKeyModifierFlags,
                            localOption: Bool, remoteShortcut: Bool) -> LocalOptionComposition.Route? {
            guard !(0xE0...0xE7).contains(usage) else { return .remote }
            if remoteShortcut {
                reset()
                return .remote
            }
            if (usage == 0x29 || usage == 0x2A), cancelPendingAccent() { return .text("") }
            guard localOption || deadKeyState != 0 else { return nil }
            guard LocalOptionComposition.isTextKey(unmodified) else {
                reset()
                return .remote
            }
            guard let layout = CatalystKeyboardLayout.current else {
                reset()
                return nil
            }
            if let pendingLayout, pendingLayout.data != layout.data || pendingLayout.keyboardType != layout.keyboardType {
                reset()
                guard localOption else { return .remote }
            }

            // Carbon uses the high byte of EventRecord.modifiers.
            var modifiers: UInt32 = localOption ? 0x08 : 0
            if flags.contains(.shift) { modifiers |= 0x02 }
            if flags.contains(.alphaShift) { modifiers |= 0x04 }
            guard let text = CatalystKeyboardLayout.translate(
                usage: usage, layout: layout, action: 0, modifiers: modifiers, options: 0, state: &deadKeyState
            ) else {
                reset()
                return nil
            }
            pendingLayout = deadKeyState == 0 ? nil : layout
            return .text(text)
        }
    }
}
#endif
