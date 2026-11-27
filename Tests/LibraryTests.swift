import XCTest
@testable import DeskLink

final class LibraryTests: XCTestCase {
    @MainActor
    func testObservationHistoryIsLocalToTheProfileAndSurvivesRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library.json")
        let endpoint = try Endpoint(address: "observe.fixture.invalid")
        var computer = Computer(name: "Work", endpoint: endpoint)
        computer.username = "fixture"
        var other = Computer(name: "Personal", endpoint: endpoint)
        other.username = "other-fixture"
        let original = ConnectionLibrary(file: file)
        XCTAssertTrue(original.save(computer))
        XCTAssertTrue(original.save(other))
        XCTAssertFalse(original.startsInObservation(computer))
        let archive = try Data(contentsOf: file)
        original.rememberObservation(true, for: computer)
        XCTAssertEqual(try Data(contentsOf: file), archive)

        let reopened = ConnectionLibrary(file: file)
        XCTAssertTrue(reopened.startsInObservation(computer))
        XCTAssertFalse(reopened.startsInObservation(other))
        let override = SessionRequest(computer: computer, password: "", rememberPassword: false, initialObservation: false)
        XCTAssertFalse(override.startsInObservation(using: reopened))
        reopened.rememberObservation(false, for: computer)
        XCTAssertFalse(ConnectionLibrary(file: file).startsInObservation(computer))
    }

    @MainActor
    func testObservationHistoryResetsWhenTheDestinationOrExplicitSettingChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library.json")
        let library = ConnectionLibrary(file: file)
        let endpoint = try Endpoint(address: "observe.fixture.invalid")
        var computer = Computer(endpoint: endpoint)
        XCTAssertTrue(library.save(computer))
        library.rememberObservation(true, for: computer)
        computer.name = "Renamed"
        XCTAssertTrue(library.save(computer))
        XCTAssertTrue(library.startsInObservation(computer))
        computer.endpoint = try Endpoint(address: "other.fixture.invalid")
        XCTAssertTrue(library.save(computer))
        XCTAssertFalse(library.startsInObservation(computer))
        computer.endpoint = endpoint
        XCTAssertTrue(library.save(computer))
        XCTAssertFalse(library.startsInObservation(computer))

        library.rememberObservation(true, for: computer)
        computer.viewOnly = true
        XCTAssertTrue(library.save(computer))
        library.rememberObservation(false, for: computer)
        XCTAssertTrue(library.startsInObservation(computer))
        computer.viewOnly = false
        XCTAssertTrue(library.save(computer))
        XCTAssertFalse(ConnectionLibrary(file: file).startsInObservation(computer))

        library.rememberObservation(true, for: computer)
        library.remove(computer)
        XCTAssertTrue(library.save(computer))
        XCTAssertFalse(ConnectionLibrary(file: file).startsInObservation(computer))
    }

    @MainActor
    func testDiscoveredConnectionReusesOnlyAnUnambiguousProfileAndKeepsItsDefaultMode() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ConnectionLibrary(file: root.appending(path: "library.json"))
        let endpoint = try Endpoint(address: "studio.fixture.invalid:15900")
        var discovered = Computer(name: "Bonjour Studio", endpoint: endpoint)
        discovered.saved = false
        var saved = Computer(name: "Work Studio", endpoint: endpoint)
        saved.authentication = .macUser
        saved.username = "fixture"
        saved.viewOnly = true
        saved.ssh = .init(port: 2222, username: "fixture-tunnel", usesKey: false)
        saved.setDisplay(.init(remoteAudio: false), for: .current)
        XCTAssertTrue(library.save(saved))
        var alternatePort = saved
        alternatePort.id = UUID()
        alternatePort.endpoint = try Endpoint(address: "studio.fixture.invalid:15901")
        XCTAssertTrue(library.save(alternatePort))

        let regular = EditorRequest.connectingToDiscovered(discovered, in: library, suggestedSSHPort: 2200, quality: nil)
        XCTAssertEqual(regular.computer?.display(for: .current).quality, .standard)
        let high = EditorRequest.connectingToDiscovered(discovered, in: library, suggestedSSHPort: 2200, quality: .adaptive)
        let connection = try XCTUnwrap(high.computer)
        XCTAssertEqual(connection.id, saved.id)
        XCTAssertEqual(connection.username, "fixture")
        XCTAssertEqual(connection.ssh, saved.ssh)
        XCTAssertTrue(connection.viewOnly)
        XCTAssertTrue(high.loadsStoredCredentials)
        XCTAssertEqual(high.suggestedSSHPort, 2200)
        XCTAssertEqual(connection.display(for: .current).quality, .adaptive)
        XCTAssertTrue(connection.display(for: .current).matchWindow)
        XCTAssertFalse(connection.display(for: .current).remoteAudio)
        library.recordSuccess(connection)
        XCTAssertEqual(library.profile(forDiscovered: endpoint)?.display(for: .current).quality, .standard)

        var secondAccount = saved
        secondAccount.id = UUID()
        secondAccount.username = "another-fixture"
        XCTAssertTrue(library.save(secondAccount))
        let ambiguous = EditorRequest.connectingToDiscovered(discovered, in: library, suggestedSSHPort: 2200, quality: .standard)
        XCTAssertEqual(ambiguous.computer?.id, discovered.id)
        XCTAssertEqual(ambiguous.computer?.username, "")
        XCTAssertNil(ambiguous.computer?.ssh)
        XCTAssertFalse(ambiguous.loadsStoredCredentials)
    }

    @MainActor
    func testDiscoveredRecentProfileCanReconnectAndStandardModeUsesTheExistingDisplay() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ConnectionLibrary(file: root.appending(path: "library.json"))
        let endpoint = try Endpoint(address: "display.fixture.invalid")
        var discovered = Computer(endpoint: endpoint)
        discovered.saved = false
        var recent = discovered
        recent.id = UUID()
        recent.username = "recent-fixture"
        recent.setDisplay(.init(quality: .adaptive, layout: .virtualPair, matchWindow: true, fixedDesktop: .standard),
                          for: .current)
        library.recordSuccess(recent)
        var link = discovered
        link.openedFromLink = true
        library.recordSuccess(link)

        let request = EditorRequest.connectingToDiscovered(discovered, in: library, suggestedSSHPort: nil, quality: .standard)
        let display = try XCTUnwrap(request.computer?.display(for: .current))
        XCTAssertEqual(request.computer?.id, recent.id)
        XCTAssertTrue(request.loadsStoredCredentials)
        XCTAssertEqual(display.quality, .standard)
        XCTAssertEqual(display.layout, .single)
        XCTAssertFalse(display.matchWindow)
        XCTAssertNil(display.fixedDesktop)
        XCTAssertEqual(library.profile(forDiscovered: endpoint)?.display(for: .current).layout, .virtualPair)
    }

    func testLibraryWindowRequestReadsExistingSavedWindowAndRoundTripsNewDestinations() throws {
        let saved = UUID()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let existing = try encoder.encode(saved)
        XCTAssertEqual(try decoder.decode(LibraryWindowRequest.self, from: existing), .connection(saved))
        XCTAssertEqual(try encoder.encode(LibraryWindowRequest.connection(saved)), existing)
        for request in [LibraryWindowRequest.quickConnect, .collection(.favorites), .collection(.folder("Studio"))] {
            XCTAssertEqual(try decoder.decode(LibraryWindowRequest.self, from: encoder.encode(request)), request)
        }
    }

    func testAppleMediaEncryptionBeforeAndAfterTheFirstPicture() {
        XCTAssertEqual(ConnectionReport.encryptionLabel(.none, route: .direct, awaitingHighPerformancePicture: true), "正在协商")
        XCTAssertEqual(ConnectionReport.encryptionLabel(.none, route: .verifiedLocal, awaitingHighPerformancePicture: false), "未加密")
        XCTAssertEqual(ConnectionReport.encryptionLabel(.none, route: .ssh, awaitingHighPerformancePicture: true), "SSH")
        XCTAssertEqual(ConnectionReport.encryptionLabel(.none, route: .custom, awaitingHighPerformancePicture: false), "未确认")
        XCTAssertEqual(ConnectionReport.encryptionLabel(.tlsX509, route: .ssh, awaitingHighPerformancePicture: false), "SSH、TLS")
        let active = ConnectionReport.encryptionLabel(.appleComCryption(cipherMode: nil, keyLength: 128, mediaSRTP: true),
                                                     route: .verifiedLocal, awaitingHighPerformancePicture: true)
        XCTAssertEqual(active, "Apple 屏幕共享加密、SRTP")
    }

    #if targetEnvironment(macCatalyst)
    @MainActor func testKeepMacAwakePersistsAcrossApplicationInstances() throws {
        let suite = "Telescope-awake-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            let first = MacAvailability(defaults: defaults)
            XCTAssertFalse(first.keepAwake)
            first.keepAwake = true
            XCTAssertTrue(first.keepAwake)
        }
        let reopened = MacAvailability(defaults: defaults)
        XCTAssertTrue(reopened.keepAwake)
        reopened.keepAwake = false
        XCTAssertFalse(reopened.keepAwake)
        XCTAssertFalse(MacAvailability(defaults: defaults).keepAwake)
    }
    #endif

    @MainActor
    func testSortKeepsManualPositionsAndCountsOnlySuccessfulConnections() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "library.json")
        let book = ConnectionLibrary(file: file)
        let host = try Endpoint(address: "sorting.fixture.invalid")
        let a = Computer(name: "Mac 10", endpoint: host)
        let unseen = Computer(name: "Elsewhere", endpoint: host)
        let b = Computer(name: "Mac 2", endpoint: host)
        let early = Date(timeIntervalSince1970: 100), late = Date(timeIntervalSince1970: 200)
        for item in [a, unseen, b] { XCTAssertTrue(book.save(item, now: early)) }
        book.recordSuccess(b, now: early)
        book.recordSuccess(b, now: early)
        book.recordSuccess(a, now: late)
        var edited = a
        edited.favorite = true
        XCTAssertTrue(book.save(edited, now: late))
        let items = book.archive.computers
        XCTAssertEqual(ComputerOrder.name.arrange(items).map(\.id), [unseen.id, b.id, a.id])
        XCTAssertEqual(ComputerOrder.lastConnected.arrange(items).map(\.id), [a.id, b.id, unseen.id])
        XCTAssertEqual(ComputerOrder.count.arrange(items).map(\.id), [b.id, a.id, unseen.id])
        XCTAssertEqual(ComputerOrder.modified.arrange(items).map(\.id), [a.id, unseen.id, b.id])
        XCTAssertFalse(book.move(unseen.id, to: b.id, within: [a.id, b.id]))
        XCTAssertTrue(book.move(a.id, to: b.id, within: [a.id, b.id]))
        XCTAssertEqual(ConnectionLibrary(file: file).archive.computers.map(\.id), [b.id, unseen.id, a.id])
        let last = try XCTUnwrap(book.archive.computers.last)
        XCTAssertEqual(last.totalConnections, 1)
        XCTAssertEqual(book.archive.duplicate(of: last).totalConnections, 0)
        var old = Computer(name: "Existing record", endpoint: host)
        old.lastConnected = early
        XCTAssertEqual(old.totalConnections, 1)
        old.recordConnection(at: late, writer: UUID())
        XCTAssertEqual(old.totalConnections, 2)
    }

    @MainActor
    func testLastReportSurvivesRelaunchAndStaysWithTheSameDestination() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "library.json")
        let book = ConnectionLibrary(file: file)
        var computer = Computer(name: "Synthetic desktop", endpoint: try Endpoint(address: "report.fixture.invalid"))
        book.recordSuccess(computer)
        func report(start: Double, sample: Double, count: UInt64) -> ConnectionReport {
            ConnectionReport(id: UUID(), startedAt: Date(timeIntervalSinceReferenceDate: start),
                             capturedAt: Date(timeIntervalSinceReferenceDate: sample), version: "RFB 3.8",
                             encryption: "TLS", width: 160, height: 96, usesVideo: false, encodings: ["Raw"],
                             frames: count, audioPackets: nil, receiveRate: 24, pointerEvents: 2, keyEvents: 2)
        }
        let recent = report(start: 100, sample: 110, count: 7)
        let legacy = try JSONDecoder().decode(ConnectionReport.self, from: JSONEncoder().encode(recent))
        XCTAssertEqual(legacy.videoCodecLabel(historical: true), "未记录视频编码")
        XCTAssertEqual(legacy.videoCodecLabel(historical: false), "等待视频帧")
        XCTAssertNil(legacy.audioPlaybackLabel)
        XCTAssertNil(legacy.connectionPathLabel)
        var measured = recent
        measured.videoCodec = 0x6876_6331
        measured.audioPlayback = .playing
        measured.route = .ssh
        let restored = try JSONDecoder().decode(ConnectionReport.self, from: JSONEncoder().encode(measured))
        XCTAssertEqual(restored.videoCodecLabel(historical: true), "HEVC")
        XCTAssertEqual(restored.audioPlaybackLabel, "播放引擎已启动")
        XCTAssertEqual(restored.connectionPathLabel, "SSH 隧道")
        book.keepReport(recent, for: computer)
        book.keepReport(report(start: 50, sample: 120, count: 15), for: computer)
        book.keepReport(report(start: 115, sample: 120, count: 0), for: computer)
        XCTAssertEqual(ConnectionLibrary(file: file).lastReport(for: computer.id), recent)
        XCTAssertFalse(String(decoding: try book.archive.encoded(), as: UTF8.self).contains("encodings"))
        var transient = computer
        transient.id = UUID()
        let updated = report(start: 100, sample: 130, count: 10)
        book.keepReport(updated, for: transient)
        XCTAssertEqual(book.lastReport(for: computer.id), updated)
        XCTAssertNil(book.lastReport(for: transient.id))
        computer.name = "Renamed"
        XCTAssertTrue(book.save(computer))
        XCTAssertEqual(book.lastReport(for: computer.id), updated)
        computer.endpoint = try Endpoint(address: "second.fixture.invalid")
        XCTAssertTrue(book.save(computer))
        XCTAssertNil(book.lastReport(for: computer.id))
        book.keepReport(updated, for: computer)
        book.remove(computer)
        XCTAssertNil(book.lastReport(for: computer.id))
    }

    @MainActor
    func testVideoFallbackPausesOnlyThisDestinationForADayAndCanBeReset() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library.json")
        let library = ConnectionLibrary(file: file)
        let start = Date(timeIntervalSinceReferenceDate: 100)
        var mac = Computer(name: "Studio", endpoint: try Endpoint(address: "studio.fixture.invalid"))
        var display = mac.display(for: .current)
        display.quality = .adaptive
        display.matchWindow = true
        display.fixedDesktop = DesktopDimensions(width: 1600, height: 1000)
        mac.setDisplay(display, for: .current)
        library.recordSuccess(mac, now: start)
        let original = try library.archive.encoded()
        XCTAssertTrue(library.pauseStreaming(for: mac, now: start))
        XCTAssertTrue(library.pauseStreaming(for: mac, now: start.addingTimeInterval(3600)))
        let end = start.addingTimeInterval(86_400)
        XCTAssertEqual(library.videoRetryDate(for: mac, now: end.addingTimeInterval(-1)), end)
        XCTAssertNil(library.videoRetryDate(for: mac, now: end))
        XCTAssertEqual(try library.archive.encoded(), original)

        let reopened = ConnectionLibrary(file: file)
        var quick = mac
        quick.id = UUID()
        let paused = try XCTUnwrap(reopened.videoRetryDate(for: quick, now: start))
        XCTAssertEqual(paused, end)
        let fallback = mac.configuration(preferences: .standard, streamingPaused: paused > start)
        XCTAssertFalse(fallback.enableHighPerformanceMode)
        XCTAssertEqual(fallback.videoQualityMode, .adaptive)
        XCTAssertEqual(fallback.displaySizingMode, .matchClient)
        XCTAssertEqual(fallback.fixedDesktopSize, CGSize(width: 1600, height: 1000))
        var changed = mac
        changed.endpoint = try Endpoint(address: "other.fixture.invalid")
        XCTAssertNil(reopened.videoRetryDate(for: changed, now: start))
        XCTAssertFalse(reopened.pauseStreaming(for: changed, now: start))

        reopened.resumeStreaming(for: quick)
        XCTAssertNil(ConnectionLibrary(file: file).videoRetryDate(for: mac, now: start))
        XCTAssertTrue(mac.configuration.enableHighPerformanceMode)
        XCTAssertTrue(reopened.pauseStreaming(for: mac, now: start))
        XCTAssertTrue(reopened.save(changed))
        XCTAssertNil(ConnectionLibrary(file: file).videoRetryDate(for: changed, now: start))
        reopened.pauseStreaming(for: changed, now: start)
        reopened.remove(changed)
        XCTAssertTrue(reopened.save(changed))
        XCTAssertNil(reopened.videoRetryDate(for: changed, now: start))
    }

    @MainActor
    func testDuplicatedConnectionKeepsSettingsAndHasIndependentHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = ConnectionLibrary(file: directory.appending(path: "library.json"))
        var original = Computer(name: "QA Mac", endpoint: try Endpoint(address: "desk.fixture.invalid:5902"))
        original.folder = "Lab"
        original.favorite = true
        original.lastConnected = Date(timeIntervalSince1970: 100)
        original.viewOnly = true
        original.ssh = SSHSettings(port: 2222, username: "desk", usesKey: true, keyName: "Test")
        var mac = original.display(for: .mac)
        mac.quality = .adaptive
        mac.lastMonitor = .display(23)
        mac.windowedMonitors = [24]
        original.setDisplay(mac, for: .mac)
        let createdAt = Date(timeIntervalSince1970: 80)
        XCTAssertTrue(book.save(original, now: createdAt))
        original.modifiedAt = createdAt
        let draft = book.archive.duplicate(of: original)
        XCTAssertEqual(book.archive.computers, [original])
        XCTAssertNotEqual(draft.id, original.id)
        XCTAssertEqual(draft.name, "QA Mac 副本")
        XCTAssertFalse(draft.favorite)
        XCTAssertNil(draft.lastConnected)
        XCTAssertEqual(draft.folder, "Lab")
        XCTAssertEqual(draft.ssh, original.ssh)
        XCTAssertTrue(draft.viewOnly)
        XCTAssertEqual(draft.display(for: .mac).quality, .adaptive)
        XCTAssertEqual(draft.display(for: .iPad).quality, .standard)
        XCTAssertNil(draft.display(for: .mac).lastMonitor)
        XCTAssertNil(draft.display(for: .mac).windowedMonitors)
        XCTAssertTrue(book.save(draft))
        XCTAssertEqual(book.archive.duplicate(of: original).name, "QA Mac 副本 2")
        book.recordSuccess(draft, now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(book.archive.computers.first, original)
        XCTAssertEqual(book.archive.computers.last?.lastConnected, Date(timeIntervalSince1970: 200))
    }

    func testAddressesRoundTripWithoutLosingNonstandardPorts() throws {
        for (input, display) in [
            ("mac.local", "mac.local"), ("vnc://MAC.local:5901/", "mac.local:5901"),
            ("desklink://[::1]:5999", "[::1]:5999"), ("::1", "[::1]"),
            ("192.168.1.2:65535", "192.168.1.2:65535")
        ] {
            let endpoint = try Endpoint(address: input)
            XCTAssertEqual(endpoint.address, display)
            XCTAssertEqual(try JSONDecoder().decode(Endpoint.self, from: JSONEncoder().encode(endpoint)), endpoint)
        }
        for invalid in ["", "vnc://", "vnc://name:secret@host", "vnc://host/path", "https://host", "host:0",
                        "host:65536", "host:", "host:-1", "a..b", "300.2.3.4", "[host]:5900", "[::1]tail", "a b", "::xx"] {
            XCTAssertThrowsError(try Endpoint(address: invalid), invalid)
        }
    }

    func testFinderVNCLocationsParseXMLAndBinaryAndRejectNonDesktopLinks() throws {
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["URL": "vnc://[::1]:5917"], format: format, options: 0)
            XCTAssertEqual(try InternetLocation.link(from: data).target, .address(try Endpoint(address: "[::1]:5917")))
        }
        for value in ["https://example.invalid", "file:///tmp/example", "vnc://host/path"] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["URL": value], format: .xml, options: 0)
            XCTAssertThrowsError(try InternetLocation.link(from: data))
        }
        let location = try PropertyListSerialization.data(fromPropertyList: ["URL": "vnc://reader:example@host?observe=true"], format: .binary, options: 0)
        let link = try InternetLocation.link(from: location)
        XCTAssertEqual(link.username, "reader")
        XCTAssertEqual(link.password, "example")
        XCTAssertEqual(link.observe, true)
    }

    @MainActor
    func testLibraryPersistsGroupsOrderAndRecentConnections() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library.json")
        let book = ConnectionLibrary(file: file)
        let first = Computer(name: "A", endpoint: try Endpoint(address: "host-a.local"))
        var second = Computer(name: "B", endpoint: try Endpoint(address: "host-b.local:5901"))
        second.folder = "Lab"
        XCTAssertTrue(book.save(first))
        XCTAssertTrue(book.save(second))
        XCTAssertTrue(book.move(second.id, to: first.id, within: [first.id, second.id]))
        var transient = Computer(endpoint: first.endpoint)
        transient.saved = false
        book.recordSuccess(transient, now: Date(timeIntervalSince1970: 123))
        let reopened = ConnectionLibrary(file: file)
        XCTAssertEqual(reopened.archive.computers.map(\.name), ["B", "A"])
        XCTAssertEqual(reopened.archive.computers.last?.lastConnected, Date(timeIntervalSince1970: 123))
        XCTAssertEqual(reopened.archive.folders, ["Lab"])
        var other = Computer(endpoint: try Endpoint(address: "third.local"))
        other.saved = false
        reopened.recordSuccess(other)
        XCTAssertFalse(try XCTUnwrap(reopened.archive.computers.last).saved)
        let imported = ConnectionLibrary(file: directory.appending(path: "import.json"))
        let data = try reopened.archive.encoded()
        XCTAssertEqual(try imported.importArchive(data), ArchiveImportResult(connections: 3, folders: 1))
        XCTAssertEqual(try imported.importArchive(data), ArchiveImportResult(duplicates: 3))
        XCTAssertEqual(imported.archive, reopened.archive)
        imported.remove(second)
        XCTAssertFalse(imported.archive.computers.contains(where: { $0.id == second.id }))
    }

    @MainActor
    func testCorruptArchiveAndFailedImportsPreserveExistingData() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library.json")
        let bad = Data("not an archive".utf8)
        try bad.write(to: file)
        let book = ConnectionLibrary(file: file)
        let computer = Computer(endpoint: try Endpoint(address: "127.0.0.1"))
        XCTAssertFalse(book.save(computer))
        XCTAssertEqual(try Data(contentsOf: file), bad)
        let clean = ConnectionLibrary(file: directory.appending(path: "new.json"))
        XCTAssertTrue(clean.save(computer))
        let snapshot = clean.archive
        XCTAssertThrowsError(try clean.importArchive(bad))
        var duplicate = snapshot
        duplicate.computers.append(computer)
        XCTAssertThrowsError(try clean.importArchive(duplicate.encoded()))
        XCTAssertEqual(snapshot, clean.archive)
    }

    func testVaultRoundTripsOnlyTheSelectedTestAccount() throws {
        let host = "desklink-" + UUID().uuidString.lowercased() + ".invalid"
        var entry = Computer(endpoint: try Endpoint(address: host))
        entry.username = "fixture-a"
        var other = entry
        other.username = "fixture-b"
        defer { try? PasswordStore.write(nil, for: entry) }
        XCTAssertNil(try PasswordStore.read(entry))
        try PasswordStore.write("generated-chart-secret", for: entry)
        XCTAssertEqual(try PasswordStore.read(entry), "generated-chart-secret")
        XCTAssertNil(try PasswordStore.read(other))
        try PasswordStore.write("rotated-chart-secret", for: entry)
        XCTAssertEqual(try PasswordStore.read(entry), "rotated-chart-secret")
        try PasswordStore.write(nil, for: entry)
        XCTAssertNil(try PasswordStore.read(entry))
    }

    @MainActor
    func testBackupRestoresGroupingOrderAndCanUndoTheRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library.json")
        let library = ConnectionLibrary(file: file)
        var first = Computer(name: "A", endpoint: try Endpoint(address: "a.invalid"))
        first.folder = "Studio"
        var second = Computer(name: "B", endpoint: try Endpoint(address: "b.invalid"))
        second.favorite = true
        XCTAssertTrue(library.save(first))
        XCTAssertTrue(library.save(second))
        XCTAssertTrue(library.move(second.id, to: first.id, within: [first.id, second.id]))
        let original = library.archive
        let saved = try XCTUnwrap(library.backups.list().first { try library.backups.read($0.id) == original })
        let ids = try library.backups.list().map(\.id)
        library.recordSuccess(first, now: Date(timeIntervalSince1970: 47))
        library.rememberMonitor(.all, for: first, windowed: [2])
        var remote = library.archive
        remote.computers[0].lastConnected = Date(timeIntervalSince1970: 48)
        XCTAssertTrue(library.applySync(remote))
        XCTAssertEqual(try library.backups.list().map(\.id), ids)
        XCTAssertTrue(library.removeFolder("Studio"))
        library.remove(first)
        let reduced = library.archive
        try library.restore(saved)
        XCTAssertEqual(ConnectionLibrary(file: file).archive, original)
        let undo = try XCTUnwrap(library.backups.list().first { try library.backups.read($0.id) == reduced })
        try library.restore(undo)
        XCTAssertEqual(ConnectionLibrary(file: file).archive, reduced)
    }

    @MainActor
    func testMovingFolderMembershipKeepsTheOtherScopeAndRecentActivity() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library.json")
        let library = ConnectionLibrary(file: file)
        let connected = Date(timeIntervalSince1970: 123)
        var dual = Computer(endpoint: try Endpoint(address: "dual.fixture.invalid"))
        dual.openedFromLink = true
        var link = Computer(endpoint: try Endpoint(address: "link.fixture.invalid"))
        link.saved = false
        link.openedFromLink = true
        XCTAssertTrue(library.save(dual))
        XCTAssertTrue(library.save(link))
        library.recordSuccess(dual, now: connected)
        XCTAssertTrue(library.addFolder("Studio"))
        XCTAssertTrue(library.addFolder("Away", in: .links))

        XCTAssertTrue(library.move(dual.id, toFolder: "Studio", in: .custom))
        XCTAssertTrue(library.move(dual.id, toFolder: "Away", in: .links))
        XCTAssertTrue(library.move(dual.id, toFolder: nil, in: .custom))
        let moved = try XCTUnwrap(library.archive.computers.first { $0.id == dual.id })
        XCTAssertNil(moved.folder)
        XCTAssertEqual(moved.linkFolder, "Away")
        XCTAssertEqual(moved.lastConnected, connected)
        XCTAssertEqual(moved.totalConnections, 1)

        let current = library.archive
        let backups = try library.backups.list().map(\.id)
        XCTAssertFalse(library.move(dual.id, toFolder: "Away", in: .links))
        XCTAssertFalse(library.move(dual.id, toFolder: "Studio", in: .links))
        XCTAssertFalse(library.move(link.id, toFolder: "Studio", in: .custom))
        XCTAssertFalse(library.move(UUID(), toFolder: "Away", in: .links))
        XCTAssertEqual(try library.backups.list().map(\.id), backups)
        XCTAssertEqual(ConnectionLibrary(file: file).archive, current)
        XCTAssertTrue(library.move(link.id, toFolder: "Away", in: .links))
        library.remove(link)
        XCTAssertFalse(library.move(link.id, toFolder: "Away", in: .links))
    }

    @MainActor
    func testBackupPreservesLegacyLibraryContainingOnlyLinkFolders() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library.json")
        var original = LibraryArchive()
        original.setFolders(["Away", "Lab"], in: .links)
        try original.encoded().write(to: file)
        let library = ConnectionLibrary(file: file)
        XCTAssertTrue(try library.backups.list().isEmpty)

        XCTAssertTrue(library.applySync(LibraryArchive()))
        let backup = try XCTUnwrap(library.backups.list().first { $0.folders == 2 })
        XCTAssertEqual(backup.computers, 0)
        try library.restore(backup)
        XCTAssertEqual(ConnectionLibrary(file: file).archive, original)
    }

    @MainActor
    func testRestoreRepairsUnreadablePrimaryAndRejectsChangedBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library.json")
        let original = ConnectionLibrary(file: file)
        let computer = Computer(endpoint: try Endpoint(address: "saved.invalid"))
        XCTAssertTrue(original.save(computer))
        let choice = try XCTUnwrap(original.backups.list().first)
        let broken = Data("partial primary".utf8)
        try broken.write(to: file, options: .atomic)
        let reopened = ConnectionLibrary(file: file)
        XCTAssertFalse(reopened.canSync)
        XCTAssertFalse(reopened.addFolder("Other"))
        XCTAssertEqual(try Data(contentsOf: file), broken)
        try reopened.restore(choice)
        XCTAssertTrue(reopened.canSync)
        XCTAssertEqual(reopened.archive, original.archive)
        let raw = try FileManager.default.contentsOfDirectory(at: reopened.backups.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "data" }
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(raw.first)), broken)
        let selected = reopened.backups.directory.appending(path: choice.id.uuidString + ".json")
        try broken.write(to: selected, options: .atomic)
        XCTAssertThrowsError(try reopened.restore(choice))
        XCTAssertTrue(try reopened.backups.list().isEmpty)
        XCTAssertEqual(try LibraryArchive.read(Data(contentsOf: file)), original.archive)
    }

    @MainActor
    func testBackupRetentionAndFailedCaptureProtectCurrentLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ConnectionLibrary(file: directory.appending(path: "library.json"))
        for index in 0..<(LibraryBackups.limit + 3) { XCTAssertTrue(library.addFolder("Group \(index)")) }
        let records = try library.backups.list()
        XCTAssertEqual(records.count, LibraryBackups.limit)
        XCTAssertEqual(records.first?.folders, LibraryBackups.limit + 3)
        let state = library.archive
        try FileManager.default.moveItem(at: library.backups.directory, to: directory.appending(path: "saved"))
        try Data([1]).write(to: library.backups.directory)
        XCTAssertFalse(library.removeFolder("Group 0"))
        XCTAssertEqual(library.archive, state)
        XCTAssertEqual(ConnectionLibrary(file: directory.appending(path: "library.json")).archive, state)
    }

    #if targetEnvironment(simulator)
    func testSynchronizedSaveMigratesOnlyThatCredential() throws {
        let entry = Computer(endpoint: try Endpoint(address: UUID().uuidString + ".invalid"))
        defer {
            try? PasswordStore.write(nil, for: entry, synchronize: true)
            try? PasswordStore.write(nil, for: entry, kind: .tailnet)
        }
        try PasswordStore.write("fixture-local", for: entry)
        XCTAssertEqual(try PasswordStore.read(entry, synchronize: true), "fixture-local")
        XCTAssertEqual(try PasswordStore.read(entry), "fixture-local")
        try PasswordStore.write("fixture-shared", for: entry, synchronize: true)
        XCTAssertNil(try PasswordStore.read(entry))
        XCTAssertEqual(try PasswordStore.read(entry, synchronize: true), "fixture-shared")
        try PasswordStore.write("fixture-api-value", for: entry, kind: .tailnet, synchronize: true)
        XCTAssertEqual(try PasswordStore.read(entry, kind: .tailnet), "fixture-api-value")
        try PasswordStore.write(nil, for: entry, synchronize: true)
        XCTAssertNil(try PasswordStore.read(entry, synchronize: true))
    }
    #endif
}
