import XCTest
import RFBProtocol
#if canImport(UIKit)
import UIKit
#endif
@testable import DeskLink
@testable import RFBTransport
@testable import rootshellVNC

@MainActor final class KeyboardPositionTests: XCTestCase {
    private var receiverAcceptsPositions = true

    #if os(iOS) && !targetEnvironment(macCatalyst)
    func testIPadSessionShortcutsLeaveOrdinaryAndTwoModifierKeysAvailable() {
        let chord: UIKeyModifierFlags = [.control, .shift, .command]
        XCTAssertEqual(IPadSessionShortcut.bindings.count, 19)
        let signatures = IPadSessionShortcut.bindings.map { $0.input + "-" + String($0.modifiers.rawValue) }
        XCTAssertEqual(Set(signatures).count, signatures.count)
        for binding in IPadSessionShortcut.bindings {
            XCTAssertEqual(IPadSessionShortcut.matching(binding.input, flags: binding.modifiers), binding.action)
        }
        XCTAssertEqual(IPadSessionShortcut.matching("H", flags: chord), .menu(.hide))
        XCTAssertEqual(IPadSessionShortcut.matching("h", flags: chord.union(.alternate)), .menu(.hideOthers))
        XCTAssertEqual(IPadSessionShortcut.matching("p", flags: chord), .password)
        XCTAssertEqual(IPadSessionShortcut.matching("|", flags: chord), .remote(.insert))
        XCTAssertEqual(IPadSessionShortcut.matching("\\", flags: chord), .remote(.backslash))
        XCTAssertNil(IPadSessionShortcut.matching("w", flags: [.command]))
        XCTAssertNil(IPadSessionShortcut.matching("2", flags: [.control, .shift]))
        XCTAssertNil(IPadSessionShortcut.matching("x", flags: chord))
    }

    func testAppSwitcherMatchesOnlyTheEffectiveCommandAndReturn() {
        func tab(_ usage: UInt32, _ flags: UIKeyModifierFlags, swapped: Bool = false) -> UInt32? {
            IPadSessionShortcut.appSwitcherTabUsage(for: usage, flags: flags, swapsCommandAndControl: swapped)
        }
        XCTAssertEqual(tab(0x28, .command), 0x2B)
        XCTAssertEqual(tab(0x28, [.command, .shift]), 0x2B)
        XCTAssertEqual(tab(0x28, .control, swapped: true), 0x2B)
        XCTAssertNil(tab(0x28, .command, swapped: true))
        XCTAssertNil(tab(0x28, []))
        XCTAssertNil(tab(0x28, [.command, .alternate]))
        XCTAssertNil(tab(0x2B, .command))
    }
    #endif

    func testReturnCanSendTabPositionTwiceWithoutReleasingHeldCommand() {
        struct Event: Equatable {
            let down: Bool
            let usage: UInt32?
            let keysym: UInt32
        }
        var wire: [Event] = []
        let handler = KeyboardInputHandler(sendKeyEvent: { down, key in
            wire.append(.init(down: down, usage: nil, keysym: key))
        }, sendPhysicalKeyEvent: { down, usage, key in
            wire.append(.init(down: down, usage: usage, keysym: key))
        })
        let input = HardwareKeyboardController(keyboardHandler: handler)
        input.synchronizeModifiers(.command)
        for _ in 0..<2 {
            XCTAssertTrue(input.press(usage: 0x28, keysym: 0xFF09, sendingAs: 0x2B))
            XCTAssertTrue(input.release(usage: 0x28))
        }
        input.synchronizeModifiers([])
        XCTAssertEqual(wire, [
            .init(down: true, usage: nil, keysym: 0xFFEB),
            .init(down: true, usage: 0x2B, keysym: 0xFF09),
            .init(down: false, usage: 0x2B, keysym: 0xFF09),
            .init(down: true, usage: 0x2B, keysym: 0xFF09),
            .init(down: false, usage: 0x2B, keysym: 0xFF09),
            .init(down: false, usage: nil, keysym: 0xFFEB),
        ])
        input.press(usage: 0x28, keysym: 0xFF09, sendingAs: 0x2B)
        input.releaseAll()
        XCTAssertEqual(wire.last, .init(down: false, usage: 0x2B, keysym: 0xFF09))
        input.press(usage: 0x28, keysym: 0xFF0D)
        input.release(usage: 0x28)
        XCTAssertEqual(wire.last, .init(down: false, usage: 0x28, keysym: 0xFF0D))
    }

    func testToolbarAndSoftwareKeyTapsKeepThePhysicalModifierDown() {
        struct Event: Equatable {
            let down: Bool
            let usage: UInt32?
            let keysym: UInt32
        }
        var wire: [Event] = []
        let capture = VNCKeyboardCapture()
        let input = RemoteInputUIView(
            touchHandler: TouchInputHandler { _, _, _ in },
            keyboardHandler: KeyboardInputHandler(
                sendKeyEvent: { wire.append(.init(down: $0, usage: nil, keysym: $1)) },
                sendPhysicalKeyEvent: { wire.append(.init(down: $0, usage: $1, keysym: $2)) }),
            keyboardCapture: capture, requestPasswordSend: {}, requestDictation: {},
            toggleFullScreen: nil, disconnect: {})
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        window.addSubview(input)
        let control = KeyboardInputHandler.keysymControlL
        input.routePhysicalModifier(.init(downFlag: true, keysym: control), usage: 0xe0)

        capture.supplementalModifiers = [.control, .fn]
        XCTAssertTrue(capture.sendToolbarKey(KeyboardInputHandler.keysymLeft, adding: .shift))
        capture.supplementalModifiers = .control
        input.insertText("a")
        input.routePhysicalModifier(.init(downFlag: false, keysym: control), usage: 0xe0)

        XCTAssertEqual(wire, [
            .init(down: true, usage: 0xe0, keysym: control),
            .init(down: true, usage: nil, keysym: KeyboardInputHandler.keysymShiftL),
            .init(down: true, usage: nil, keysym: KeyboardInputHandler.keysymHome),
            .init(down: false, usage: nil, keysym: KeyboardInputHandler.keysymHome),
            .init(down: false, usage: nil, keysym: KeyboardInputHandler.keysymShiftL),
            .init(down: true, usage: nil, keysym: 0x61),
            .init(down: false, usage: nil, keysym: 0x61),
            .init(down: false, usage: 0xe0, keysym: control),
        ])
        input.removeFromSuperview()
        XCTAssertFalse(capture.sendToolbarKey(KeyboardInputHandler.keysymTab))
        XCTAssertEqual(wire.count, 8)
    }

    func testHardwareKeyboardCallbacksFollowTheKeyWindowAndTextFocus() async throws {
        struct Event: Equatable {
            let window: Int
            let down: Bool
            let keysym: UInt32
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let original = scene.keyWindow
        var events: [Event] = []
        let windows = (0...1).map { _ in UIWindow(windowScene: scene) }
        defer {
            windows.forEach { $0.isHidden = true }
            original?.makeKey()
        }
        let inputs = windows.enumerated().map { index, window in
            let root = UIViewController()
            window.rootViewController = root
            let view = RemoteInputUIView(touchHandler: TouchInputHandler { _, _, _ in },
                keyboardHandler: KeyboardInputHandler(
                    sendKeyEvent: { events.append(.init(window: index, down: $0, keysym: $1)) },
                    sendPhysicalKeyEvent: { events.append(.init(window: index, down: $0, keysym: $2)) }),
                keyboardCapture: VNCKeyboardCapture(), requestPasswordSend: {}, requestDictation: {},
                toggleFullScreen: nil, disconnect: {})
            root.view.addSubview(view)
            return view
        }
        let localField = UITextField()
        windows[1].rootViewController?.view.addSubview(localField)
        let control = KeyboardInputHandler.keysymControlL

        func drainCallbacks() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        windows[0].makeKeyAndVisible()
        XCTAssertTrue(inputs[0].becomeFirstResponder())
        inputs[0].dispatchMonitoredHardwareEvent {
            $0.routePhysicalModifier(.init(downFlag: true, keysym: control), usage: 0xe0)
        }
        await drainCallbacks()
        XCTAssertEqual(events, [.init(window: 0, down: true, keysym: control)])

        inputs[0].dispatchMonitoredHardwareEvent { $0.insertText("x") }
        windows[1].makeKeyAndVisible()
        XCTAssertTrue(inputs[1].becomeFirstResponder())
        inputs[1].dispatchMonitoredHardwareEvent { $0.insertText("b") }
        await drainCallbacks()
        XCTAssertEqual(events, [
            .init(window: 0, down: true, keysym: control),
            .init(window: 0, down: false, keysym: control),
            .init(window: 1, down: true, keysym: 0x62),
            .init(window: 1, down: false, keysym: 0x62),
        ])

        XCTAssertTrue(localField.becomeFirstResponder())
        let beforeLocalFocus = events
        inputs[1].dispatchMonitoredHardwareEvent { $0.insertText("y") }
        await drainCallbacks()
        XCTAssertEqual(events, beforeLocalFocus)

        windows[0].makeKey()
        if !inputs[0].isFirstResponder { XCTAssertTrue(inputs[0].becomeFirstResponder()) }
        inputs[0].dispatchMonitoredHardwareEvent { $0.insertText("a") }
        await drainCallbacks()
        XCTAssertEqual(events, beforeLocalFocus + [
            .init(window: 0, down: true, keysym: 0x61),
            .init(window: 0, down: false, keysym: 0x61),
        ])
    }

    #if targetEnvironment(macCatalyst)
    func testMacLocalOptionUsesTheActualKeyboardLayoutAndIsolatesDeadKeys() throws {
        var input = CatalystKeyboardLayout.LocalOptionInput()
        func press(_ usage: UInt32, _ key: String, flags: UIKeyModifierFlags = [],
                   local: Bool = false, shortcut: Bool = false) -> LocalOptionComposition.Route? {
            input.route(usage: usage, unmodified: key, flags: flags, localOption: local, remoteShortcut: shortcut)
        }
        let a = press(0x04, "a", flags: .alternate, local: true)
        try XCTSkipUnless(a == .text("å"), "This fixture uses the Mac ABC input source.")
        XCTAssertEqual(press(0x08, "e", flags: .alternate, local: true), .text(""))
        XCTAssertEqual(press(0x08, "e"), .text("é"))
        XCTAssertEqual(press(0x1F, "2", flags: [.shift, .alternate], local: true), .text("€"))
        XCTAssertEqual(press(0x11, "n", flags: .alternate, local: true), .text(""))
        XCTAssertEqual(press(0x11, "n", flags: .shift), .text("Ñ"))
        XCTAssertEqual(press(0x08, "e", flags: .alternate, local: true), .text(""))
        XCTAssertEqual(press(0x29, UIKeyCommand.inputEscape), .text(""))
        XCTAssertNil(press(0x08, "e"))
        XCTAssertEqual(press(0x08, "e", flags: .alternate, local: true), .text(""))
        XCTAssertEqual(press(0x06, "c", shortcut: true), .remote)
        XCTAssertNil(press(0x08, "e"))
    }
    #endif

    func testLocalOptionChoosesOneSideAndPreservesTheOppositeModifier() {
        let chord: VNCKeyboardModifiers = [.option, .shift]
        var state = LocalOptionKeyState()
        state.update(usage: 0xE2, down: true)
        XCTAssertEqual(state.remoteModifiers(chord), chord)
        for side in [VNCLocalOptionKey.left, .right] {
            state.side = side
            let local: UInt32 = side == .left ? 0xE2 : 0xE6
            let other: UInt32 = side == .left ? 0xE6 : 0xE2
            XCTAssertTrue(state.owns(local))
            XCTAssertFalse(state.owns(other))
            XCTAssertEqual(state.remoteModifiers(chord), chord)
            state.update(usage: local, down: true)
            XCTAssertEqual(state.remoteModifiers(chord), .shift)
            state.update(usage: other, down: true)
            XCTAssertEqual(state.remoteModifiers(chord), chord)
            state.update(usage: other, down: false)
            XCTAssertEqual(state.remoteModifiers(chord), .shift)
            state.releaseAll()
            XCTAssertEqual(state.remoteModifiers(chord), chord)
        }
    }

    func testLocalOptionComposesSystemMarksAndKnownEmptyKeyboardEvents() {
        var input = LocalOptionComposition()
        func press(_ usage: UInt32, _ text: String, _ base: String, local: Bool = false,
                   shortcut: Bool = false) -> LocalOptionComposition.Route {
            input.route(usage: usage, characters: text, unmodified: base,
                        localOption: local, remoteShortcut: shortcut)
        }
        XCTAssertEqual(press(4, "å", "a", local: true), .text("å"))
        XCTAssertEqual(press(8, "", "e", local: true), .native)
        XCTAssertTrue(input.receiveMark("å e"))
        XCTAssertEqual(press(8, "E", "e"), .text("É"))
        XCTAssertEqual(press(17, "", "n", local: true), .native)
        XCTAssertTrue(input.receiveMark("˜"))
        XCTAssertEqual(press(17, "n", "n"), .text("ñ"))
        XCTAssertEqual(press(25, "", "v", local: true), .native)
        XCTAssertTrue(input.receiveMark("ˇ"))
        XCTAssertEqual(press(6, "c", "c"), .text("č"))
        XCTAssertEqual(press(8, "", "e", local: true), .native)
        XCTAssertEqual(press(44, " ", " "), .text("´"))
        XCTAssertEqual(press(17, "", "n", local: true), .native)
        XCTAssertEqual(press(0x2A, "\u{8}", "\u{8}"), .text(""))
        XCTAssertEqual(press(17, "n", "n"), .remote)
        XCTAssertEqual(press(8, "", "e", local: true), .native)
        XCTAssertEqual(press(25, "v", "v", shortcut: true), .remote)
        XCTAssertFalse(input.receiveMark("´"))
        XCTAssertEqual(press(8, "e", "e"), .remote)
    }

    func testLocalTextLiftRestoresTheHeldShiftAndKeepsCharacterOnly() {
        var events: [HardwareKeyboardTransition] = []
        let handler = KeyboardInputHandler(sendKeyEvent: { down, keysym in
            events.append(.init(downFlag: down, keysym: keysym))
        })
        let input = HardwareKeyboardController(keyboardHandler: handler)
        input.press(usage: 0xE1, keysym: KeyboardInputHandler.keysymShiftL)
        input.whileShiftIsReleased { handler.typeText("€") }
        XCTAssertTrue(input.release(usage: 0xE1))
        XCTAssertEqual(events.map(\.downFlag), [true, false, true, false, true, false])
        XCTAssertEqual(events.map(\.keysym), [0xFFE1, 0xFFE1, 0x010020AC, 0x010020AC, 0xFFE1, 0xFFE1])
    }

    func testRemotePositionsAreIndependentOfTheLocalCharacterAndKeyboardGeometry() {
        XCTAssertEqual(MacKeyboardPosition.keyCode(for: 0x14), 0x0C) // US Q, French A
        XCTAssertEqual(MacKeyboardPosition.keyCode(for: 0x04), 0x00)
        XCTAssertEqual(MacKeyboardPosition.keyCode(for: 0x2B), 0x30)
        XCTAssertEqual(MacKeyboardPosition.keyCode(for: 0x64), 0x0A) // ISO extra key
        XCTAssertEqual(MacKeyboardPosition.keyCode(for: 0x89), 0x5D) // JIS Yen
        XCTAssertEqual(MacKeyboardPosition.keyCode(for: 0x58), 0x4C) // Keypad Enter
        XCTAssertEqual(MacKeyboardPosition.keyCode(for: 0x6F), 0x5A) // F20
        XCTAssertEqual(MacKeyboardPosition.keyCode(for: 0xE7), 0x36) // Right Command
        XCTAssertNil(MacKeyboardPosition.keyCode(for: 0xFF))
    }

    func testHardwareSwapPreservesSidesAndLeavesToolbarAndCommandAliasAlone() {
        var symbols = [UInt32]()
        var physical = [UInt32]()
        let handler = KeyboardInputHandler(
            sendKeyEvent: { down, symbol in symbols.append(down ? symbol : 0) },
            sendPhysicalKeyEvent: { down, usage, _ in physical.append(down ? usage : 0) }
        )
        let input = HardwareKeyboardController(keyboardHandler: handler)
        input.swapsCommandAndControl = true
        input.press(usage: 0xE4, keysym: KeyboardInputHandler.keysymControlR)
        input.release(usage: 0xE4)
        input.synchronizeModifiers(.command)
        input.synchronizeModifiers([])
        XCTAssertEqual(symbols, [KeyboardInputHandler.keysymSuperR, 0, KeyboardInputHandler.keysymControlL, 0])

        symbols.removeAll()
        input.synchronizeModifiers([.control, .option])
        input.releaseAll()
        handler.handleKeysymTap(KeyboardInputHandler.keysymControlL, supplementalModifiers: [])
        XCTAssertEqual(symbols, [KeyboardInputHandler.keysymSuperL, 0, KeyboardInputHandler.keysymControlL, 0])

        input.controlOptionAsCommand = false
        for usage: UInt32 in [0xE0, 0xE4, 0xE3, 0xE7, 0xE1] {
            input.press(usage: usage, keysym: KeyboardInputHandler.keysymForHIDUsage(usage, characters: ""))
            input.release(usage: usage)
        }
        XCTAssertEqual(physical, [0xE3, 0, 0xE7, 0, 0xE0, 0, 0xE4, 0, 0xE1, 0])
        input.press(usage: 0xE0, keysym: KeyboardInputHandler.keysymControlL)
        input.swapsCommandAndControl = false
        XCTAssertFalse(input.hasPressedKeys)
        input.press(usage: 0xE0, keysym: KeyboardInputHandler.keysymControlL)
        input.release(usage: 0xE0)
        XCTAssertEqual(Array(physical.suffix(4)), [0xE3, 0, 0xE0, 0])
    }

    func testNegotiatedInputPreservesThePositionAndUsesUnicodeForCommittedText() {
        var positions = [UInt32]()
        var hints = [UInt32]()
        var characters = [UInt32]()
        var keyDowns = 0
        let handler = KeyboardInputHandler(
            sendKeyEvent: { down, symbol in if down { characters.append(symbol) } },
            sendPhysicalKeyEvent: { down, usage, hint in
                if down { positions.append(usage); hints.append(hint) }
            },
            physicalKeySupported: { [self] in receiverAcceptsPositions && MacKeyboardPosition.keyCode(for: $0) != nil }
        ).notifyingKeyDown { keyDowns += 1 }
        let input = HardwareKeyboardController(keyboardHandler: handler)
        input.keyRepeat = VNCKeyRepeat(enabled: false)
        XCTAssertTrue(input.press(usage: 0x14, keysym: 0x61))
        XCTAssertTrue(input.release(usage: 0x14))
        XCTAssertTrue(input.press(usage: 0x90, keysym: 0))
        input.releaseAll()
        XCTAssertTrue(input.press(usage: 0xFF, keysym: 0x62))
        XCTAssertTrue(input.release(usage: 0xFF))
        handler.typeText("中🙂")
        receiverAcceptsPositions = false
        XCTAssertTrue(input.press(usage: 0x14, keysym: 0x61))
        XCTAssertTrue(input.release(usage: 0x14))
        XCTAssertFalse(input.press(usage: 0x90, keysym: 0))
        XCTAssertEqual(positions, [0x14, 0x90])
        XCTAssertEqual(hints, [0x61, 0])
        XCTAssertEqual(characters, [0x62, 0x01004E2D, 0x0101F642, 0x61])
        XCTAssertEqual(keyDowns, 6)
    }

    func testUnicodeOptionUsesTheMacPositionThroughTheMatchingKeyUp() {
        for translatesControlOption in [false, true] {
            for useShift in [false, true] {
                var positions: [(down: Bool, code: UInt16)] = []
                var symbols: [UInt32] = []
                let handler = KeyboardInputHandler(
                    sendKeyEvent: { down, key in if down { symbols.append(key) } },
                    usesAppleModifierConvention: { true },
                    sendPhysicalKeyEvent: { down, usage, _ in
                        if let code = MacKeyboardPosition.keyCode(for: usage) { positions.append((down, code)) }
                    },
                    physicalKeySupported: { _ in false },
                    optionPhysicalKeySupported: { MacKeyboardPosition.keyCode(for: $0) != nil }
                ).notifyingKeyDown {}
                let keyboard = HardwareKeyboardController(keyboardHandler: handler)
                keyboard.controlOptionAsCommand = translatesControlOption
                keyboard.keyRepeat = VNCKeyRepeat(enabled: false)
                if useShift { keyboard.press(usage: 0xE5, keysym: KeyboardInputHandler.keysymShiftR) }
                keyboard.press(usage: 0xE6, keysym: KeyboardInputHandler.keysymMetaR)
                XCTAssertTrue(keyboard.canPress(usage: 0x08, keysym: 0)) // An Option dead key has no local character.
                XCTAssertTrue(keyboard.press(usage: 0x08, keysym: 0))
                XCTAssertTrue(keyboard.release(usage: 0xE6))
                XCTAssertTrue(keyboard.release(usage: 0x08))
                if useShift { keyboard.release(usage: 0xE5) }

                XCTAssertFalse(keyboard.canPress(usage: 0x08, keysym: 0))
                XCTAssertTrue(keyboard.press(usage: 0x14, keysym: 0x61))
                XCTAssertTrue(keyboard.release(usage: 0x14))
                XCTAssertEqual(positions.map(\.down), [true, false])
                XCTAssertEqual(positions.map(\.code), [0x0E, 0x0E])
                XCTAssertEqual(symbols.last, 0x61)
                XCTAssertFalse(keyboard.hasPressedKeys)
            }
        }
    }

    func testUnicodeOptionLeavesUnsupportedHostsAndKeyboardShortcutsInCharacterTransport() {
        for supportsPosition in [false, true] {
            var positions: [UInt32] = []
            var symbols: [UInt32] = []
            let handler = KeyboardInputHandler(
                sendKeyEvent: { down, key in if down { symbols.append(key) } },
                usesAppleModifierConvention: { true },
                sendPhysicalKeyEvent: { _, usage, _ in positions.append(usage) },
                physicalKeySupported: { _ in false },
                optionPhysicalKeySupported: { _ in supportsPosition }
            )
            let keyboard = HardwareKeyboardController(keyboardHandler: handler)
            keyboard.keyRepeat = VNCKeyRepeat(enabled: false)

            // With no negotiated Apple position support, Option keeps the Unicode glyph.
            if supportsPosition { keyboard.press(usage: 0xE3, keysym: KeyboardInputHandler.keysymSuperL) }
            keyboard.press(usage: 0xE2, keysym: KeyboardInputHandler.keysymMetaL)
            XCTAssertTrue(keyboard.press(usage: 0x14, keysym: 0x00E5))
            XCTAssertTrue(keyboard.release(usage: 0x14))
            // Navigation keys keep their existing representation.
            XCTAssertTrue(keyboard.press(usage: 0x50, keysym: KeyboardInputHandler.keysymLeft))
            keyboard.releaseAll()
            XCTAssertTrue(positions.isEmpty)
            XCTAssertEqual(Array(symbols.suffix(2)), [0x00E5, KeyboardInputHandler.keysymLeft])
        }
    }

    func testEncryptedPositionDownAndUpMatchIndependentReferenceBlocks() throws {
        let key = Data(UInt8(0)...UInt8(15))
        let cipher = try XCTUnwrap(AppleEncryptedInputCipher(key: key))
        let down = try XCTUnwrap(cipher.keyPositionMessage(down: true, keysym: 0x61, keyCode: 0x0C, microseconds: 0x01020304))
        let up = try XCTUnwrap(cipher.keyPositionMessage(down: false, keysym: 0x61, keyCode: 0x0C, microseconds: 1))
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(down), "1001e30284353ff6fd16a6c14942bbfb0592")
        XCTAssertEqual(hex(up), "1001fa07d8b50b9c107ee92c7f174df3e81d")
        XCTAssertEqual(cipher.keyMessage(down: true, keysym: 0x61), AppleEncryptedInput.keyMessage(down: true, keysym: 0x61, key: key))
    }

    func testHardwareAndSoftwareLegacyModesSendTheirOwnRFBKeysyms() {
        @MainActor
        final class Mapping {
            var hardwareLegacy = true
            var softwareLegacy = false
        }
        let mapping = Mapping()
        var packets: [Data] = []
        let handler = KeyboardInputHandler(
            sendKeyEvent: { down, symbol in
                packets.append(ClientMessage.keyEvent(downFlag: down, key: symbol).serialize())
            }, usesLegacyHardwareMapping: { mapping.hardwareLegacy },
            usesLegacySoftwareMapping: { mapping.softwareLegacy }
        ).notifyingKeyDown {}
        let keyboard = HardwareKeyboardController(keyboardHandler: handler)
        keyboard.keyRepeat = VNCKeyRepeat(enabled: false)

        XCTAssertTrue(keyboard.press(usage: 0x1A, keysym: 0x0100_03C9))
        mapping.hardwareLegacy = false
        XCTAssertTrue(keyboard.release(usage: 0x1A))
        handler.typeText("ω")
        mapping.softwareLegacy = true
        XCTAssertTrue(keyboard.press(usage: 0x1A, keysym: 0x0100_03C9))
        keyboard.releaseAll()
        handler.typeText("яĄ€🙂\t")
        mapping.hardwareLegacy = true
        handler.typeHardwareText("€")
        mapping.softwareLegacy = false
        handler.typeText("€")

        func tap(_ bytes: [UInt8]) -> [Data] {
            [Data([4, 1, 0, 0] + bytes), Data([4, 0, 0, 0] + bytes)]
        }
        let expected: [[UInt8]] = [
            [0, 0, 0x07, 0xF9],     // Hardware ω with Legacy enabled.
            [1, 0, 0x03, 0xC9],     // Software ω with Unicode enabled.
            [1, 0, 0x03, 0xC9],     // Hardware ω with Unicode enabled.
            [0, 0, 0x06, 0xD1],     // Legacy Cyrillic, Latin-2 and Euro keysyms.
            [0, 0, 0x01, 0xA1],
            [0, 0, 0x20, 0xAC],
            [1, 1, 0xF6, 0x42],     // Character with no legacy alias.
            [0, 0, 0xFF, 0x09],     // Tab remains a navigation key.
            [0, 0, 0x20, 0xAC],     // Committed hardware text uses Hardware mode.
            [1, 0, 0x20, 0xAC],
        ]
        XCTAssertEqual(packets, expected.flatMap { tap($0) })
    }

    func testTigerVNCFirstKeyCompatibilityIsOptInAndSurvivesArchive() throws {
        var computer = Computer(endpoint: try Endpoint(address: "keyboard.fixture.invalid"))
        let old = try JSONEncoder().encode(computer)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("preparesTigerVNCKeyboard"))
        XCTAssertFalse(try JSONDecoder().decode(Computer.self, from: old).configuration.preparesTigerVNCKeyboard)
        computer.preparesTigerVNCKeyboard = true
        let restored = try LibraryArchive.read(LibraryArchive(computers: [computer]).encoded())
        XCTAssertEqual(restored.computers.first?.configuration.preparesTigerVNCKeyboard, true)
    }

    func testNewAndArchivedComputersPreserveTheSelectedHardwareMode() throws {
        var computer = Computer(endpoint: try Endpoint(address: "keyboard.fixture.invalid"))
        XCTAssertTrue(computer.configuration.usesMacHardwareKeyPositions)
        computer.usesMacHardwareKeyPositions = false
        let archive = try LibraryArchive.read(LibraryArchive(computers: [computer]).encoded())
        XCTAssertEqual(archive.computers.first?.usesMacHardwareKeyPositions, false)
        computer.usesMacHardwareKeyPositions = nil
        let old = try JSONEncoder().encode(computer)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("usesMacHardwareKeyPositions"))
        let decoded = try JSONDecoder().decode(Computer.self, from: old)
        XCTAssertFalse(decoded.configuration.usesMacHardwareKeyPositions)
        XCTAssertNil(VNCSession(configuration: computer.configuration).macKeyCode(forHardwareUsage: 0x14))
    }
}
