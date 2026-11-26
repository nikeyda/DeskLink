import XCTest
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
