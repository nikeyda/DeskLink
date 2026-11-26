import rootshellVNC
import UniformTypeIdentifiers
import XCTest
@testable import DeskLink

@MainActor
final class ScreensArchiveTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testOriginalExportsOpenAsDocumentsOnThisDevice() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Export.screens")
        let library = ConnectionLibrary(file: root.appending(path: "library.json"))
        XCTAssertEqual(UTType(filenameExtension: "screens")?.identifier, ArchiveDocument.screensType.identifier)
        XCTAssertEqual(ArchiveDocument.writableContentTypes, [ArchiveDocument.type, ArchiveDocument.screensType])
        try fixture("screens-direct").write(to: file)
        let direct = try ArchiveDocument(contentsOf: file)
        XCTAssertTrue(direct.fromScreens)
        let plain = try XCTUnwrap(LibraryArchive.read(direct.data).computers.first)
        XCTAssertEqual(plain.name, "Telescope Archive Fixture 7F39")
        XCTAssertEqual(plain.endpoint.address, "archive-7f39.example.invalid:5917")
        XCTAssertEqual(plain.username, "example-user")
        XCTAssertNil(plain.ssh)
        try fixture("screens-group-ssh").write(to: file)
        let grouped = try ArchiveDocument(contentsOf: file)
        XCTAssertEqual(try library.importArchive(grouped.data), ArchiveImportResult(connections: 1, folders: 1))
        XCTAssertEqual(try library.importArchive(grouped.data), ArchiveImportResult(duplicates: 1))
        let stored = try XCTUnwrap(ConnectionLibrary(file: root.appending(path: "library.json")).archive.computers.first)
        XCTAssertEqual(stored.id, plain.id)
        XCTAssertEqual(stored.folder, "Telescope Test Group 7F39")
        XCTAssertEqual(stored.ssh, SSHSettings(port: 2227, username: "example-ssh", server: "relay-7f39.example.invalid"))
        XCTAssertEqual(stored.display(for: .mac).rememberMonitor, true)
        XCTAssertEqual(stored.display(for: .iPad).rememberMonitor, true)
    }

    func testOriginalRaspberryPiRSAProfilePreservesUserAndRequiresEncryptedAuthentication() throws {
        let archive = try ScreensArchive.convert(fixture("screens-rsa-pi"))
        let stored = try LibraryArchive.read(archive.encoded())
        var computer = try XCTUnwrap(stored.computers.first)
        XCTAssertTrue(computer.usesRaspberryPiRSAAES)
        XCTAssertEqual(computer.username, "fixture")
        XCTAssertEqual(computer.configuration.securityPolicy, .rsaAES)
        let exported = try ScreensArchive.export(stored, knownMacs: [], sharedClipboard: true)
        let restored = try XCTUnwrap(ScreensArchive.convert(exported).computers.first)
        XCTAssertEqual(restored.configuration.securityPolicy, .rsaAES)
        XCTAssertEqual(restored.screensOperatingSystem, 5)
        XCTAssertEqual(restored.username, computer.username)
        computer.usesRaspberryPiRSAAES = false
        XCTAssertEqual(computer.configuration.securityPolicy, .automatic)
        var manual = Computer(endpoint: try Endpoint(address: "rsa71.invalid"))
        manual.usesRaspberryPiRSAAES = true
        XCTAssertEqual(manual.screensOperatingSystem, restored.screensOperatingSystem)
        XCTAssertEqual(manual.screensAuthenticationMethod, restored.screensAuthenticationMethod)
    }

    func testOrdinaryVNCPasswordExportFromOriginalApp() throws {
        let entry = try XCTUnwrap(ScreensArchive.convert(fixture("screens-generic")).computers.first)
        XCTAssertEqual(entry.endpoint.address, "generic-2b61.example.invalid")
        XCTAssertEqual(entry.username, "")
        XCTAssertNil(entry.ssh)
        XCTAssertEqual(entry.screensAuthenticationMethod, 2)
        XCTAssertEqual(entry.screensOperatingSystem, 6)
        XCTAssertEqual(entry.usesMacHardwareKeyPositions, false)
    }

    func testMacKeyboardPositionPreferenceSurvivesScreensRoundTrip() throws {
        var source = try ScreensArchive.convert(fixture("screens-direct"))
        XCTAssertEqual(source.computers.first?.usesMacHardwareKeyPositions, true)
        source.computers[0].usesMacHardwareKeyPositions = false
        let exported = try ScreensArchive.export(source, knownMacs: [], sharedClipboard: false)
        let imported = try ScreensArchive.convert(exported)
        XCTAssertEqual(imported.computers.first?.usesMacHardwareKeyPositions, false)
    }

    func testPerComputerCursorAndDragDelaySurviveBothArchiveFormats() throws {
        let suite = "DeskLinkTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: "connection.clientCursor")
        preferences.set(0.85, forKey: "gesture.holdDuration")
        var original = try ScreensArchive.convert(fixture("screens-direct"))
        XCTAssertEqual(original.computers[0].showsLocalCursor, true)
        XCTAssertEqual(original.computers[0].touchHoldDuration, 0.3)
        XCTAssertEqual(original.computers[0].configuration(preferences: preferences).cursorRendering, .client)
        let inherited = Computer(name: "Inherited", endpoint: try Endpoint(address: "pointer-fixture.invalid"))
        original.computers.append(inherited)
        let native = try LibraryArchive.read(original.encoded())
        XCTAssertNil(native.computers[1].touchHoldDuration)
        XCTAssertNil(native.computers[1].showsLocalCursor)
        XCTAssertEqual(native.computers[1].configuration(preferences: preferences).cursorRendering, .server)
        let exported = try ScreensArchive.export(native, knownMacs: [], sharedClipboard: false, preferences: preferences)
        let imported = try ScreensArchive.convert(exported)
        XCTAssertEqual(imported.computers.map(\.showsLocalCursor), [true, false])
        XCTAssertEqual(imported.computers.map(\.touchHoldDuration), [0.3, 0.85])
    }

    func testExportSavedProfilesAndPreserveSSHWithoutIncludingSecretsOrRecents() throws {
        var source = try ScreensArchive.convert(fixture("screens-group-ssh"))
        let generic = try XCTUnwrap(ScreensArchive.convert(fixture("screens-generic")).computers.first)
        source.computers.append(generic)
        var recent = Computer(name: "Recent only", endpoint: try Endpoint(address: "temporary.invalid"))
        recent.saved = false
        source.computers.append(recent)
        let data = try ScreensArchive.export(source, knownMacs: [], sharedClipboard: false)
        XCTAssertEqual(data, try ScreensArchive.export(source, knownMacs: [], sharedClipboard: false))
        let again = try ScreensArchive.convert(data)
        XCTAssertEqual(again.computers.map(\.id), Array(source.computers.prefix(2)).map(\.id))
        XCTAssertEqual(again.folders, source.folders)
        XCTAssertEqual(again.computers.first?.ssh, source.computers.first?.ssh)
        XCTAssertEqual(again.computers.first?.folder, source.folders.first)
        XCTAssertTrue(again.computers.allSatisfy { $0.automaticallySharesClipboard == false })
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: ArchiveDocument.screensType.identifier)
        attachment.name = "Telescope-Interop.screens"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testExportRequiresKnownAuthenticationForNewNamedAccounts() throws {
        var source = LibraryArchive()
        var entry = Computer(name: "Unknown", endpoint: try Endpoint(address: "new.invalid"))
        entry.username = "fixture"
        source.computers = [entry]
        XCTAssertThrowsError(try ScreensArchive.export(source, knownMacs: [], sharedClipboard: true))
        let data = try ScreensArchive.export(source, knownMacs: [entry.id], sharedClipboard: true)
        XCTAssertEqual(try ScreensArchive.convert(data).computers.first?.username, "fixture")
        source.computers[0].ssh = SSHSettings(username: "test", usesKey: true)
        XCTAssertThrowsError(try ScreensArchive.export(source, knownMacs: [entry.id], sharedClipboard: true))
    }

    private func modified(fixture name: String = "screens-direct", _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
        var screens = try XCTUnwrap(document["screens"] as? [[String: Any]])
        edit(&screens[0])
        document["screens"] = screens
        return try JSONSerialization.data(withJSONObject: document)
    }

    func testPCScrollSpeedPreservesEachSliderPositionAcrossArchiveFormats() throws {
        let original = try ScreensArchive.convert(fixture("screens-pc-scroll"))
        XCTAssertEqual(original.computers.first?.pcScrollSpeed, .moderatelyFast)
        for (position, percent) in [50, 75, 100, 150, 200].enumerated() {
            let data = try modified(fixture: "screens-pc-scroll") { $0["pcScrollSpeed"] = position }
            let imported = try ScreensArchive.convert(data)
            let restored = try JSONDecoder().decode(LibraryArchive.self, from: JSONEncoder().encode(imported))
            let computer = try XCTUnwrap(restored.computers.first)
            XCTAssertEqual(computer.scrollSpeed(forMac: false).rawValue, percent)
            XCTAssertEqual(computer.scrollSpeed(forMac: true), .standard)
            let exported = try ScreensArchive.export(restored, knownMacs: [], sharedClipboard: true)
            let output = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
            let screens = try XCTUnwrap(output["screens"] as? [[String: Any]])
            XCTAssertEqual(screens.first?["pcScrollSpeed"] as? Int, position)
        }
        let legacy = try modified { $0.removeValue(forKey: "pcScrollSpeed") }
        XCTAssertNil(try XCTUnwrap(ScreensArchive.convert(legacy).computers.first).pcScrollSpeed)
        for unknown in [-1, 5] {
            let data = try modified { $0["pcScrollSpeed"] = unknown }
            XCTAssertThrowsError(try ScreensArchive.convert(data))
        }
    }

    func testDisconnectScreenshotPreferenceSurvivesNativeAndScreensArchives() throws {
        let original = try ScreensArchive.convert(fixture("screens-pc-scroll"))
        XCTAssertEqual(original.computers.first?.savesDisconnectScreenshot, true)
        for enabled: Bool? in [true, false, nil] {
            let imported = try ScreensArchive.convert(modified { $0["grabScreenshot"] = enabled })
            let native = try LibraryArchive.read(imported.encoded())
            XCTAssertEqual(native.computers.first?.savesDisconnectScreenshot == true, enabled == true)
            let exported = try ScreensArchive.export(native, knownMacs: [], sharedClipboard: true)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
            let screens = try XCTUnwrap(root["screens"] as? [[String: Any]])
            XCTAssertEqual(screens.first?["grabScreenshot"] as? Bool, enabled == true)
        }
    }

    func testObservationPrivacyAndIPv6SurviveMigration() throws {
        let data = try modified {
            $0["hostname"] = "[2001:db8::11]"
            $0["startInObserveMode"] = true
            $0["useSharedClipboard"] = false
            $0["streamVideoAndAudio"] = false
            $0["useSecureConnection"] = true
        }
        let imported = try XCTUnwrap(ScreensArchive.convert(data).computers.first)
        XCTAssertTrue(imported.viewOnly)
        XCTAssertEqual(imported.automaticallySharesClipboard, false)
        XCTAssertFalse(imported.remoteAudio)
        XCTAssertEqual(imported.smoothVideo, false)
        XCTAssertEqual(imported.endpoint.address, "[2001:db8::11]:5917")
        XCTAssertEqual(imported.ssh, SSHSettings(port: 22, username: "example-user"))
    }

    func testZoomSettingSurvivesBothArchiveFormatsAndDefaultsToEnabled() throws {
        for disabled: Bool? in [nil, true, false] {
            let source = try modified { $0["turnOffZooming"] = disabled }
            let imported = try ScreensArchive.convert(source)
            let native = try LibraryArchive.read(imported.encoded())
            XCTAssertEqual(native.computers.first?.configuration.allowsViewportZoom, disabled != true)
            let exported = try ScreensArchive.export(native, knownMacs: [], sharedClipboard: true)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
            let records = try XCTUnwrap(object["screens"] as? [[String: Any]])
            XCTAssertEqual(records.first?["turnOffZooming"] as? Bool, disabled == true)
        }
    }

    func testRemoteBellSettingSurvivesBothArchiveFormats() throws {
        for flag: Bool? in [nil, true, false] {
            let data = try modified { $0["allowBellSignal"] = flag }
            let imported = try ScreensArchive.convert(data)
            let native = try LibraryArchive.read(imported.encoded())
            let computer = try XCTUnwrap(native.computers.first)
            XCTAssertEqual(computer.configuration.serverBellHandler != nil, flag != false)
            let exported = try ScreensArchive.export(native, knownMacs: [], sharedClipboard: true)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
            let screens = try XCTUnwrap(json["screens"] as? [[String: Any]])
            XCTAssertEqual(screens.first?["allowBellSignal"] as? Bool, flag != false)
        }
    }

    func testHardwareCommandAndControlSwapSurvivesBothArchiveFormats() throws {
        for flag: Bool? in [nil, false, true] {
            let data = try modified { $0["permuteCmdAndCtrlModifierKeys"] = flag }
            let imported = try ScreensArchive.convert(data)
            let native = try LibraryArchive.read(imported.encoded())
            let computer = try XCTUnwrap(native.computers.first)
            XCTAssertEqual(computer.configuration.swapsHardwareCommandAndControl, flag == true)
            let exported = try ScreensArchive.export(native, knownMacs: [], sharedClipboard: true)
            let restored = try ScreensArchive.convert(exported)
            XCTAssertEqual(restored.computers.first?.configuration.swapsHardwareCommandAndControl, flag == true)
        }
    }

    func testAllOriginalDisconnectActionsSurviveBothArchiveFormats() throws {
        // One export per menu item on the same fixture computer in Screens 5.10.5.
        let observed: [VNCDisconnectAction?] = [
            nil, .topLeft, .topRight, .bottomLeft, .bottomRight, .logOutUser, .lockScreen, .controlAltDelete
        ]
        let samples = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("screens-disconnect-samples")) as? [String: Any])
        XCTAssertEqual(samples.count, observed.count)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (code, action) in observed.enumerated() {
            let sample = try XCTUnwrap(samples[String(code)])
            let original = try JSONSerialization.data(withJSONObject: sample)
            let file = root.appending(path: "sample.screens")
            try original.write(to: file)
            let document = try ArchiveDocument(contentsOf: file)
            XCTAssertTrue(document.fromScreens)
            let libraryFile = root.appending(path: "library-\(code).json")
            XCTAssertEqual(try ConnectionLibrary(file: libraryFile).importArchive(document.data),
                           ArchiveImportResult(connections: 1))
            let stored = ConnectionLibrary(file: libraryFile).archive
            XCTAssertEqual(try XCTUnwrap(stored.computers.first).disconnectAction, action)
            let exported = try ScreensArchive.export(stored, knownMacs: [], sharedClipboard: true)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
            let records = try XCTUnwrap(object["screens"] as? [[String: Any]])
            XCTAssertEqual(records.first?["onDisconnectAction"] as? Int, code)
            if action == .topRight {
                let attachment = XCTAttachment(data: exported, uniformTypeIdentifier: ArchiveDocument.screensType.identifier)
                attachment.name = "Telescope-disconnect-top-right.screens"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testUnsupportedAccessModesAndInvalidRoutesDoNotImport() throws {
        for change: (inout [String: Any]) -> Void in [
            { $0["useCurtainMode"] = true },
            { $0["authenticationMethod"] = 999 },
            { $0["onDisconnectAction"] = 99 },
            { $0["useSecureConnection"] = true; $0["sshPort"] = 0 },
            { $0["hostname"] = "archive-7f39.example.invalid:666" },
            { $0["users"] = [["username": "first"], ["username": "second"]] }
        ] {
            let data = try modified(change)
            XCTAssertThrowsError(try ScreensArchive.convert(data))
        }
    }
}
