import rootshellVNC
import RFBTransport
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

    func testSecureConnectionsLocallySurvivesBothArchiveFormats() throws {
        let included = try modified(fixture: "screens-group-ssh") { $0["useSecureConnectionsLocally"] = false }
        let imported = try ScreensArchive.convert(included)
        let restored = try LibraryArchive.read(imported.encoded())
        let selected = try XCTUnwrap(restored.computers.first)
        XCTAssertEqual(selected.ssh?.secureLocally, false)
        let defaultArchive = try ScreensArchive.convert(fixture("screens-group-ssh"))
        let defaultRoute = try XCTUnwrap(defaultArchive.computers.first)
        XCTAssertNil(defaultRoute.ssh?.secureLocally)
        XCTAssertTrue(defaultRoute.hasSameDestination(as: selected))

        for (archive, expected) in [(restored, false), (defaultArchive, true)] {
            let output = try ScreensArchive.export(archive, knownMacs: [], sharedClipboard: true)
            let document = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
            let entries = try XCTUnwrap(document["screens"] as? [[String: Any]])
            XCTAssertEqual(entries.first?["useSecureConnectionsLocally"] as? Bool, expected)
            let route = try XCTUnwrap(try ScreensArchive.convert(output).computers.first?.ssh)
            XCTAssertEqual(route.secureLocally != false, expected)
        }
        let omitted = try modified(fixture: "screens-group-ssh") { $0.removeValue(forKey: "useSecureConnectionsLocally") }
        XCTAssertNil(try ScreensArchive.convert(omitted).computers.first?.ssh?.secureLocally)
    }

    func testMixedOriginalArchiveRetainsExternalFoldersOnImportAndExport() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Mixed.screens")
        let libraryFile = root.appending(path: "library.json")
        let library = ConnectionLibrary(file: libraryFile)
        var source = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("screens-group-ssh")) as? [String: Any])
        let id = UUID().uuidString
        let tailscale: [[String: Any]] = [["id": id, "name": "Studio", "items": [UUID().uuidString],
                                           "rawItems": ["fixture-node-A"], "contentType": 16]]
        let connect: [[String: Any]] = [["id": id, "name": "Studio", "items": [],
                                          "rawItems": ["fixture-computer-A"], "contentType": 32]]
        source["tsFolders"] = tailscale
        source["scFolders"] = connect
        try JSONSerialization.data(withJSONObject: source).write(to: file)
        let document = try ArchiveDocument(contentsOf: file)
        XCTAssertEqual(try library.importArchive(document.data), ArchiveImportResult(connections: 1, folders: 1, directoryFolders: 2))
        XCTAssertEqual(try library.importArchive(document.data), ArchiveImportResult(duplicates: 1))
        let saved = ConnectionLibrary(file: libraryFile).archive
        XCTAssertEqual(saved.computers.first?.folder, "Telescope Test Group 7F39")
        XCTAssertEqual(saved.folderCount, 3)
        XCTAssertEqual(try library.backups.list().first?.folders, 3)
        let exported = try ScreensArchive.export(saved, knownMacs: [], sharedClipboard: true)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertEqual(record["tsFolders"] as? NSArray, tailscale as NSArray)
        XCTAssertEqual(record["scFolders"] as? NSArray, connect as NSArray)
        XCTAssertEqual(try ScreensArchive.convert(exported).screensDirectoryFolders, saved.screensDirectoryFolders)
    }

    func testDirectoryFolderDuplicatesAreRejectedAndLegacyOmissionsStillDecode() throws {
        var source = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("screens-direct")) as? [String: Any])
        source.removeValue(forKey: "scFolders")
        source.removeValue(forKey: "tsFolders")
        let legacy = try JSONSerialization.data(withJSONObject: source)
        XCTAssertEqual(try ScreensArchive.convert(legacy).computers.count, 1)
        XCTAssertNil(try ScreensArchive.convert(legacy).screensDirectoryFolders)
        let duplicate: [String: Any] = ["id": UUID().uuidString, "name": "Duplicate", "items": [], "contentType": 16]
        source["tsFolders"] = [duplicate, duplicate]
        let malformed = try JSONSerialization.data(withJSONObject: source)
        XCTAssertThrowsError(try ScreensArchive.convert(malformed)) { error in
            guard case ScreensArchive.ImportError.unsupportedFolder = error else { return XCTFail("Unexpected error: \(error)") }
        }
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
        XCTAssertEqual(entry.authentication, .vncPassword)
        XCTAssertEqual(entry.configuration.securityPolicy, .vncAuthentication)
        XCTAssertEqual(entry.screensOperatingSystem, 6)
        XCTAssertEqual(entry.usesMacHardwareKeyPositions, false)
    }

    func testMacUserProfilesRoundTripAndKeepAutomaticAvailableForNativeConnections() throws {
        let imported = try ScreensArchive.convert(fixture("screens-direct"))
        let original = try XCTUnwrap(imported.computers.first)
        XCTAssertEqual(original.authentication, .macUser)
        XCTAssertEqual(original.username, "example-user")

        var manual = Computer(endpoint: original.endpoint)
        manual.username = "fixture-mac"
        XCTAssertEqual(manual.configuration.securityPolicy, .automatic)
        manual.authentication = .macUser
        XCTAssertEqual(manual.screensOperatingSystem, 1)

        for computer in [original, manual] {
            let native = try LibraryArchive.read(LibraryArchive(computers: [computer]).encoded())
            let stored = try XCTUnwrap(native.computers.first)
            XCTAssertEqual(stored.configuration.securityPolicy, .macUser)
            let output = try ScreensArchive.export(native, knownMacs: [], sharedClipboard: true)
            let restored = try XCTUnwrap(ScreensArchive.convert(output).computers.first)
            XCTAssertEqual(restored.authentication, .macUser)
            XCTAssertEqual(restored.screensOperatingSystem, 1)
            XCTAssertEqual(restored.username, computer.username)
        }

        manual.username = " "
        XCTAssertNil(try SessionRequest.remembered(for: manual, synchronize: false))
        manual.authentication = .automatic
        XCTAssertNil(manual.screensAuthenticationMethod)
        XCTAssertEqual(manual.configuration.securityPolicy, .automatic)
    }

    func testUnauthenticatedProfileSurvivesBothArchivesAndIsSeparateFromSavedPasswords() throws {
        let raw = try modified(fixture: "screens-generic") {
            $0["authenticationMethod"] = 3
            $0["users"] = []
        }
        let archive = try ScreensArchive.convert(raw)
        let stored = try LibraryArchive.read(archive.encoded())
        var noAuthentication = try XCTUnwrap(stored.computers.first)
        XCTAssertEqual(noAuthentication.authentication, .unauthenticated)
        XCTAssertEqual(noAuthentication.configuration.securityPolicy, .none)
        XCTAssertEqual(noAuthentication.username, "")
        XCTAssertEqual(try SessionRequest.remembered(for: noAuthentication, synchronize: false)?.password, "")
        let privateCopy = try ScreensArchive.export(stored, knownMacs: [], sharedClipboard: true)
        let roundTrip = try XCTUnwrap(ScreensArchive.convert(privateCopy).computers.first)
        XCTAssertEqual(roundTrip.screensAuthenticationMethod, 3)
        XCTAssertEqual(roundTrip.configuration.securityPolicy, .none)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: privateCopy) as? [String: Any])
        let records = try XCTUnwrap(document["screens"] as? [[String: Any]])
        XCTAssertEqual(records.first?["users"] as? NSArray, [])

        // Native libraries saved before the picker existed retain automatic negotiation.
        var old = Computer(endpoint: noAuthentication.endpoint)
        old.screensOperatingSystem = 6
        old.screensAuthenticationMethod = 2
        let migrated = try XCTUnwrap(LibraryArchive.read(LibraryArchive(computers: [old]).encoded()).computers.first)
        XCTAssertEqual(migrated.authentication, .automatic)
        XCTAssertFalse(migrated.hasSameDestination(as: noAuthentication))

        noAuthentication.authentication = .vncPassword
        XCTAssertEqual(noAuthentication.configuration.securityPolicy, .vncAuthentication)
        XCTAssertTrue(migrated.hasSameDestination(as: noAuthentication))
        noAuthentication.authentication = .automatic
        XCTAssertEqual(noAuthentication.configuration.securityPolicy, .automatic)
    }

    func testDisplayColorDepthAndAdaptivePolicySurviveBothArchiveFormats() throws {
        for (wire, bits, policyWire, policy) in [(3, 8, 0, FramebufferQuality.Scope.never),
                                                (1, 16, 1, .remoteOnly), (2, 32, 2, .always)] {
            let input = try modified(fixture: "screens-generic") {
                $0["colorDepth"] = wire
                $0["adaptiveQualityMode"] = policyWire
            }
            let imported = try ScreensArchive.convert(input)
            let stored = try LibraryArchive.read(imported.encoded())
            let computer = try XCTUnwrap(stored.computers.first)
            XCTAssertEqual(computer.display(for: .current).colorDepth?.rawValue ?? 32, bits)
            XCTAssertEqual(Int(computer.configuration.preferredPixelFormat?.bitsPerPixel ?? 32), bits)
            XCTAssertEqual(computer.configuration.framebufferQuality?.adaptive, policy)
            let output = try ScreensArchive.export(stored, knownMacs: [], sharedClipboard: true)
            let document = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
            let entry = try XCTUnwrap((document["screens"] as? [[String: Any]])?.first)
            XCTAssertEqual(entry["colorDepth"] as? Int, wire)
            XCTAssertEqual(entry["adaptiveQualityMode"] as? Int, policyWire)
        }
    }

    func testDisplayProfilesImportPerClientAndDriveTheConnectionConfiguration() throws {
        func profile(_ mode: String, width: Int, height: Int, count: Int, retina: Bool) -> [String: Any] {
            ["renderingProtocol": 1, "hasChosenRenderingProtocol": true, "sizingMode": mode,
             "selectedVirtualDisplayCount": count, "customWidth": width, "customHeight": height, "useRetina": retina]
        }
        let input = try modified {
            $0["desktopDisplayPreferences"] = [
                "mac", profile("custom", width: 1680, height: 1050, count: 2, retina: false),
                "iPad", profile("dynamic", width: 1440, height: 900, count: 1, retina: true),
                "iPhone", profile("custom", width: 960, height: 540, count: 1, retina: false),
                "vision", profile("custom", width: 1920, height: 1080, count: 2, retina: true),
            ] as [Any]
        }
        let imported = try ScreensArchive.convert(input)
        let stored = try LibraryArchive.read(imported.encoded())
        let computer = try XCTUnwrap(stored.computers.first)
        XCTAssertEqual(computer.display(for: .mac).layout, .virtualPair)
        XCTAssertEqual(computer.display(for: .mac).fixedDesktop, DesktopDimensions(width: 1680, height: 1050))
        XCTAssertEqual(computer.display(for: .mac).retinaResolution, false)
        XCTAssertEqual(computer.display(for: .iPad).layout, .single)
        XCTAssertTrue(computer.display(for: .iPad).matchWindow)
        XCTAssertNil(computer.display(for: .iPad).fixedDesktop)
        XCTAssertEqual(computer.display(for: .iPhone).fixedDesktop, DesktopDimensions(width: 960, height: 540))

        let configuration = computer.configuration
        XCTAssertTrue(configuration.enableHighPerformanceMode)
        XCTAssertEqual(configuration.displaySizingMode, .matchClient)
        switch DisplayClient.current {
        case .mac:
            XCTAssertEqual(configuration.displayMode, .twoVirtualDisplays)
            XCTAssertEqual(configuration.fixedDesktopSize, CGSize(width: 1680, height: 1050))
            XCTAssertFalse(configuration.usesRetinaResolution)
        case .iPad:
            XCTAssertEqual(configuration.displayMode, .oneDisplay)
            XCTAssertNil(configuration.fixedDesktopSize)
            XCTAssertTrue(configuration.usesRetinaResolution)
        case .iPhone:
            XCTAssertEqual(configuration.fixedDesktopSize, CGSize(width: 960, height: 540))
        case .vision:
            XCTAssertEqual(configuration.fixedDesktopSize, CGSize(width: 1920, height: 1080))
        }

        let output = try ScreensArchive.export(stored, knownMacs: [], sharedClipboard: true)
        let roundTrip = try XCTUnwrap(ScreensArchive.convert(output).computers.first)
        for client in DisplayClient.allCases { XCTAssertEqual(roundTrip.display(for: client), computer.display(for: client)) }
    }

    func testOldProfilesAndUnsupportedDepthsKeepTheirFallbacks() throws {
        let old = try modified {
            $0["colorDepth"] = 0
            $0["adaptiveQualityMode"] = 99
            $0.removeValue(forKey: "desktopDisplayPreferences")
        }
        var computer = try XCTUnwrap(ScreensArchive.convert(old).computers.first)
        XCTAssertNil(computer.display(for: .current).colorDepth)
        XCTAssertEqual(computer.display(for: .mac).quality, .standard)
        XCTAssertEqual(computer.configuration.framebufferQuality?.adaptive, .always)

        var previousMobileProfile = computer.display(for: .iPad)
        previousMobileProfile.quality = .adaptive
        computer.setDisplay(previousMobileProfile, for: .iPad)
        XCTAssertEqual(computer.display(for: .iPhone), previousMobileProfile)
        var phoneProfile = previousMobileProfile
        phoneProfile.fixedDesktop = DesktopDimensions(width: 960, height: 540)
        computer.setDisplay(phoneProfile, for: .iPhone)
        XCTAssertEqual(computer.display(for: .iPhone), phoneProfile)
        XCTAssertEqual(computer.display(for: .iPad), previousMobileProfile)

        computer.setDisplay(previousMobileProfile, for: .iPhone, explicit: true)
        computer.setDisplay(phoneProfile, for: .iPad)
        XCTAssertEqual(computer.display(for: .iPhone), previousMobileProfile)
        XCTAssertEqual(computer.display(for: .iPad), phoneProfile)
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
        XCTAssertFalse(original.computers[0].configuration(preferences: preferences).usesFallbackCursor)
        original.computers[0].usesFallbackCursor = true
        XCTAssertEqual(original.computers[0].touchHoldDuration, 0.3)
        XCTAssertEqual(original.computers[0].configuration(preferences: preferences).cursorRendering, .client)
        let inherited = Computer(name: "Inherited", endpoint: try Endpoint(address: "pointer-fixture.invalid"))
        original.computers.append(inherited)
        let native = try LibraryArchive.read(original.encoded())
        XCTAssertNil(native.computers[1].touchHoldDuration)
        XCTAssertNil(native.computers[1].showsLocalCursor)
        XCTAssertEqual(native.computers[0].usesFallbackCursor, true)
        XCTAssertNil(native.computers[1].usesFallbackCursor)
        XCTAssertEqual(native.computers[1].configuration(preferences: preferences).cursorRendering, .server)
        let exported = try ScreensArchive.export(native, knownMacs: [], sharedClipboard: false, preferences: preferences)
        let imported = try ScreensArchive.convert(exported)
        XCTAssertEqual(imported.computers.map(\.showsLocalCursor), [true, false])
        XCTAssertEqual(imported.computers.map { $0.configuration(preferences: preferences).usesFallbackCursor }, [true, false])
        XCTAssertEqual(imported.computers.map(\.touchHoldDuration), [0.3, 0.85])
    }

    func testPortableCodecsRoundTripThroughOriginalWindowsAndNativeArchives() throws {
        var archive = try ScreensArchive.convert(fixture("screens-codecs"))
        let original = try XCTUnwrap(archive.computers.first)
        XCTAssertEqual(original.disabledVNCCodecs, [7, 16])
        XCTAssertEqual(original.configuration.disabledPortableCodecs, [.tight, .zrle])
        archive.computers[0].disabledVNCCodecs = PortableFramebufferCodec.allCases.map(\.rawValue).sorted()
        let native = try LibraryArchive.read(archive.encoded())
        let screens = try ScreensArchive.convert(ScreensArchive.export(native, knownMacs: [], sharedClipboard: true))
        XCTAssertEqual(screens.computers[0].disabledVNCCodecs, archive.computers[0].disabledVNCCodecs)
        XCTAssertEqual(screens.computers[0].configuration.disabledPortableCodecs, Set(PortableFramebufferCodec.allCases))
        XCTAssertEqual(screens.computers[0].configuration.cursorRendering, .server)
    }

    func testTightJPEGQualityAndCompressionScopeRoundTripThroughBothArchiveFormats() throws {
        var archive = try ScreensArchive.convert(fixture("screens-tight-jpeg"))
        let original = try XCTUnwrap(archive.computers.first?.framebufferQuality)
        XCTAssertEqual(original.compression, .always)
        XCTAssertEqual(original.resolvedTightJPEGQuality, 9)
        for scope in FramebufferQuality.Scope.allCases {
            for level in FramebufferQuality.tightJPEGQualityRange {
                archive.computers[0].framebufferQuality = FramebufferQuality(compression: scope, tightJPEGQuality: level)
                let native = try LibraryArchive.read(archive.encoded())
                XCTAssertEqual(native.computers[0].framebufferQuality, archive.computers[0].framebufferQuality)
                let screens = try ScreensArchive.convert(ScreensArchive.export(native, knownMacs: [], sharedClipboard: true))
                let restored = try XCTUnwrap(screens.computers.first).configuration.framebufferQuality
                XCTAssertEqual(restored?.compression, scope)
                XCTAssertEqual(restored?.resolvedTightJPEGQuality, level)
            }
        }
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

    func testInitialFramingSurvivesBothArchiveFormats() throws {
        let cases: [(Int?, RemoteViewportSizing?)] = [
            (nil, nil), (0, nil), (1, .fill), (2, .actualSize), (999, nil),
        ]
        for (initial, expected) in cases {
            let source = try modified { $0["initialScalingMode"] = initial }
            let imported = try ScreensArchive.convert(source)
            let native = try LibraryArchive.read(imported.encoded())
            XCTAssertEqual(try XCTUnwrap(native.computers.first).initialViewportSizing, expected)
            let exported = try ScreensArchive.export(native, knownMacs: [], sharedClipboard: true)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
            let records = try XCTUnwrap(object["screens"] as? [[String: Any]])
            XCTAssertEqual(records.first?["initialScalingMode"] as? Int, (expected ?? .fit).rawValue)
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

    func testAutomaticCurtainAndMessageSurviveBothArchiveFormats() throws {
        for enabled in [true, false] {
            let message = "维护中 🔒\n请稍候"
            let archive = try ScreensArchive.convert(try modified {
                $0["useCurtainMode"] = enabled
                $0["curtainModeMessage"] = message
            })
            let entry = try XCTUnwrap(LibraryArchive.read(archive.encoded()).computers.first)
            XCTAssertEqual(entry.curtainsDisplayOnConnect == true, enabled)
            XCTAssertEqual(entry.curtainMessage, message)
            XCTAssertEqual(entry.configuration.automaticCurtainMessage, enabled ? message : nil)
            var observe = entry
            observe.viewOnly = true
            XCTAssertNil(observe.configuration.automaticCurtainMessage)

            let exported = try ScreensArchive.export(archive, knownMacs: [], sharedClipboard: true)
            let roundTrip = try XCTUnwrap(ScreensArchive.convert(exported).computers.first)
            XCTAssertEqual(roundTrip.curtainsDisplayOnConnect == true, enabled)
            XCTAssertEqual(roundTrip.curtainMessage, message)
        }
        let legacy = try XCTUnwrap(ScreensArchive.convert(try modified {
            $0.removeValue(forKey: "useCurtainMode")
            $0.removeValue(forKey: "curtainModeMessage")
        }).computers.first)
        XCTAssertNil(legacy.configuration.automaticCurtainMessage)
        let noMessage = try XCTUnwrap(ScreensArchive.convert(try modified {
            $0["useCurtainMode"] = true
            $0.removeValue(forKey: "curtainModeMessage")
        }).computers.first)
        XCTAssertEqual(noMessage.configuration.automaticCurtainMessage, "")
    }

    func testCursorTrackingSpeedSurvivesBothArchiveFormats() throws {
        for speed in [0.5, 1, 1.37, 2] {
            let source = try modified { $0["cursorTrackingSpeed"] = speed }
            let archive = try ScreensArchive.convert(source)
            let native = try LibraryArchive.read(archive.encoded())
            XCTAssertEqual(native.computers.first?.cursorTrackingSpeed, speed)
            let exported = try ScreensArchive.export(native, knownMacs: [], sharedClipboard: true)
            XCTAssertEqual(try ScreensArchive.convert(exported).computers.first?.cursorTrackingSpeed, speed)
        }

        let older = try modified { $0.removeValue(forKey: "cursorTrackingSpeed") }
        XCTAssertNil(try ScreensArchive.convert(older).computers.first?.cursorTrackingSpeed)
        let invalid = try modified { $0["cursorTrackingSpeed"] = -1 }
        XCTAssertNil(try ScreensArchive.convert(invalid).computers.first?.cursorTrackingSpeed)
    }
}
