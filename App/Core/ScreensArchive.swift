import Foundation
import RFBTransport
import rootshellVNC

private extension FramebufferQuality.Scope {
    init?(screensCompressionMode: Int) {
        switch screensCompressionMode {
        case 0: self = .never
        case 1: self = .remoteOnly
        case 2: self = .always
        default: return nil
        }
    }

    var screensCompressionMode: Int {
        switch self {
        case .never: 0
        case .remoteOnly: 1
        case .always: 2
        }
    }
}

private extension VNCDisconnectAction {
    var screensArchiveValue: Int {
        switch self {
        case .topLeft: 1
        case .topRight: 2
        case .bottomLeft: 3
        case .bottomRight: 4
        case .logOutUser: 5
        case .lockScreen: 6
        case .controlAltDelete: 7
        }
    }
}

private extension RemoteScrollSpeed {
    // Screens archives store slider positions. Native profiles store percentages.
    var screensPosition: Int {
        switch self {
        case .slow: 0
        case .moderatelySlow: 1
        case .standard: 2
        case .moderatelyFast: 3
        case .fast: 4
        }
    }
}

/// Connection settings exported by Screens 5.10.5 using General → Export.
struct ScreensArchive: Decodable {
    private struct Folder: Decodable {
        let name: String
        let items: [UUID]
        let contentType: Int
    }

    private enum EntryType: Decodable { case saved }

    private struct User: Decodable { let username: String? }

    private struct Screen: Decodable {
        let version: Int
        let id: UUID
        let type: EntryType
        let name: String?
        let hostname: String
        let port: UInt16
        let clientProtocol: String
        let users: [User]
        let authenticationMethod: Int
        let operatingSystem: Int
        let hardwareKeyboardMode: Int?
        let permuteCmdAndCtrlModifierKeys: Bool?
        let showLocalCursor: Bool?
        let useFallbackCursor: Bool?
        let disabledCodecs: [Int32]?
        let imageCompressionMode: Int?
        let tightVncJPEGEncodingQuality: Int?
        let turnOffZooming: Bool?
        let onScreenDragDelay: TimeInterval?
        let pcScrollSpeed: Int?
        let startInObserveMode: Bool
        let useCurtainMode: Bool
        let onDisconnectAction: Int
        let grabScreenshot: Bool?
        let useSharedClipboard: Bool
        let allowBellSignal: Bool?
        let enableMomentumScrolling: Bool?
        let rememberLastSelectedDisplay: Bool?
        let streamVideoAndAudio: Bool?
        let useSecureConnection: Bool
        let sshHostname: String?
        let sshPort: UInt16?
        let sshUsers: [User]?

        func computer() throws -> Computer {
            guard version == 6, clientProtocol == "vnc", ([1, 2].contains(authenticationMethod) || (authenticationMethod == 5 && operatingSystem == 5)),
                  !useCurtainMode, users.count <= 1 else {
                throw ImportError.unsupportedConnection
            }
            let host = try Endpoint.hostOnly(hostname)
            var result = Computer(name: name ?? "", endpoint: try Endpoint(address: host, defaultPort: port))
            result.id = id
            result.savesDisconnectScreenshot = grabScreenshot == true ? true : nil
            if onDisconnectAction != 0 {
                guard let action = VNCDisconnectAction.allCases.first(where: { $0.screensArchiveValue == onDisconnectAction }) else {
                    throw ImportError.unsupportedConnection
                }
                result.disconnectAction = action
            }
            if authenticationMethod == 1 || authenticationMethod == 5 {
                result.username = users.first?.username ?? ""
            }
            result.screensOperatingSystem = operatingSystem
            result.screensAuthenticationMethod = authenticationMethod
            result.swapsHardwareCommandAndControl = permuteCmdAndCtrlModifierKeys == true ? true : nil
            result.showsLocalCursor = showLocalCursor
            result.usesFallbackCursor = useFallbackCursor == true ? true : nil
            if let disabledCodecs, !disabledCodecs.isEmpty {
                result.disabledVNCCodecs = Set(disabledCodecs).sorted()
            }
            var framebuffer = FramebufferQuality()
            if let mode = imageCompressionMode, let compression = FramebufferQuality.Scope(screensCompressionMode: mode) {
                framebuffer.compression = compression
            }
            if let quality = tightVncJPEGEncodingQuality, FramebufferQuality.tightJPEGQualityRange.contains(quality),
               quality != FramebufferQuality.defaultTightJPEGQuality {
                framebuffer.tightJPEGQuality = quality
            }
            result.framebufferQuality = framebuffer == FramebufferQuality() ? nil : framebuffer
            result.allowsViewportZoom = turnOffZooming == true ? false : nil
            result.touchHoldDuration = onScreenDragDelay
            if let pcScrollSpeed {
                guard let speed = RemoteScrollSpeed.allCases.first(where: { $0.screensPosition == pcScrollSpeed }) else {
                    throw ImportError.unsupportedConnection
                }
                result.pcScrollSpeed = speed == .standard ? nil : speed
            }
            if operatingSystem != 1 || hardwareKeyboardMode == 2 {
                result.usesMacHardwareKeyPositions = false
            }
            result.viewOnly = startInObserveMode
            // The application-wide clipboard preference still applies when sharing was permitted.
            result.automaticallySharesClipboard = useSharedClipboard ? nil : false
            result.allowsRemoteBell = allowBellSignal == false ? false : nil
            result.momentumScrolling = enableMomentumScrolling
            if let media = streamVideoAndAudio, !media {
                result.remoteAudio = false
                result.smoothVideo = false
            }
            if let rememberLastSelectedDisplay {
                for client in [DisplayClient.mac, .iPad] {
                    var display = result.display(for: client)
                    display.rememberMonitor = rememberLastSelectedDisplay
                    result.setDisplay(display, for: client)
                }
            }
            if useSecureConnection {
                let names = sshUsers ?? []
                guard names.count <= 1 else { throw ImportError.unsupportedConnection }
                let username = names.first?.username.flatMap { $0.isEmpty ? nil : $0 } ?? result.username
                guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let sshPort, sshPort > 0 else { throw ImportError.incompleteSSH }
                let server = try sshHostname.flatMap { $0.isEmpty ? nil : try Endpoint.hostOnly($0) }
                result.ssh = SSHSettings(port: sshPort, username: username, server: server)
            }
            return result
        }
    }

    private let screens: [Screen]
    private let folders: [Folder]
    private let tsFolders: [Folder]
    private let scFolders: [Folder]

    enum ImportError: LocalizedError {
        case unsupportedConnection, incompleteSSH, unsupportedFolder

        var errorDescription: String? {
            switch self {
            case .unsupportedConnection: "此归档包含暂不支持的连接类型、认证方式或会话设置。请选择普通 VNC 连接或使用单个账户的 SSH 隧道。"
            case .incompleteSSH: "SSH 隧道缺少有效的端口或用户名。请在原连接中补全后再导出。"
            case .unsupportedFolder: "此归档包含暂不支持的分组或目录服务记录。"
            }
        }
    }

    static func convert(_ data: Data) throws -> LibraryArchive {
        let source = try JSONDecoder().decode(Self.self, from: data)
        guard source.tsFolders.isEmpty, source.scFolders.isEmpty else { throw ImportError.unsupportedFolder }
        var result = LibraryArchive()
        result.computers = try source.screens.map { try $0.computer() }
        let ids = Set(result.computers.map(\.id))
        guard ids.count == result.computers.count else { throw CocoaError(.fileReadCorruptFile) }
        var membership: [UUID: String] = [:]
        for folder in source.folders {
            guard folder.contentType == 8 else { throw ImportError.unsupportedFolder }
            result.folders.append(folder.name)
            for id in folder.items {
                guard ids.contains(id), membership.updateValue(folder.name, forKey: id) == nil else {
                    throw ImportError.unsupportedFolder
                }
            }
        }
        for index in result.computers.indices {
            result.computers[index].folder = membership[result.computers[index].id]
        }
        return result
    }
}

extension ScreensArchive {
    /// New, password-only VNC records use the generic host profile. A Mac user
    /// profile requires evidence of an Apple session or an imported profile.
    static func export(_ archive: LibraryArchive, knownMacs: Set<UUID>, sharedClipboard: Bool,
                       preferences: UserDefaults = .standard) throws -> Data {
        guard let file = Bundle.main.url(forResource: "ScreensV6Defaults", withExtension: "plist"),
              let defaults = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let computers = archive.computers.filter(\.saved)
        let screens: [[String: Any]] = try computers.map { computer in
            let system: Int
            let authentication: Int
            if let importedSystem = computer.screensOperatingSystem, let method = computer.screensAuthenticationMethod {
                system = importedSystem
                authentication = method
            } else if knownMacs.contains(computer.id), !computer.username.isEmpty {
                system = 1
                authentication = 1
            } else if computer.username.isEmpty {
                system = 6
                authentication = 2
            } else { throw ExportError.unknownAuthentication(computer.displayName) }
            guard authentication != 2 || computer.username.isEmpty else { throw ExportError.unknownAuthentication(computer.displayName) }
            guard computer.ssh?.usesKey != true else {
                throw ExportError.unsupportedSetting(computer.displayName)
            }
            var record = defaults
            let id = computer.id.uuidString
            record["version"] = 6
            record["type"] = ["saved": [String: String]()]
            record["clientProtocol"] = "vnc"
            record["id"] = id
            record["restorationIdentifier"] = id + ".saved"
            record["name"] = computer.displayName
            record["hostname"] = computer.endpoint.host
            record["port"] = Int(computer.endpoint.port)
            record["operatingSystem"] = system
            record["authenticationMethod"] = authentication
            record["hardwareKeyboardMode"] = system == 1 && computer.usesMacHardwareKeyPositions == true ? 0 : 2
            func user(_ name: String?, role: String) -> [String: Any] {
                let identity = "local.nikey.desklink/screens/" + id + "/" + role + "/" + (name ?? "")
                var entry: [String: Any] = ["id": UUID.derived(from: identity).uuidString, "username": NSNull()]
                if let name, !name.isEmpty { entry["username"] = name }
                return entry
            }
            record["users"] = [user(computer.username, role: "desktop")]
            record["useSecureConnection"] = computer.ssh != nil
            record["sshHostname"] = computer.ssh?.server
            record["sshPort"] = Int(computer.ssh?.port ?? 22)
            record["sshUsers"] = [user(computer.ssh?.username, role: "ssh")]
            record["onDisconnectAction"] = computer.disconnectAction?.screensArchiveValue ?? 0
            record["grabScreenshot"] = computer.savesDisconnectScreenshot == true
            record["pcScrollSpeed"] = (computer.pcScrollSpeed ?? .standard).screensPosition
            record["startInObserveMode"] = computer.viewOnly
            record["showLocalCursor"] = computer.showsLocalCursor ?? (preferences.object(forKey: "connection.clientCursor") as? Bool ?? true)
            record["useFallbackCursor"] = computer.usesFallbackCursor == true
            record["disabledCodecs"] = computer.disabledVNCCodecs ?? []
            let framebuffer = computer.framebufferQuality ?? FramebufferQuality()
            record["imageCompressionMode"] = framebuffer.compression.screensCompressionMode
            record["tightVncJPEGEncodingQuality"] = framebuffer.resolvedTightJPEGQuality
            record["turnOffZooming"] = computer.allowsViewportZoom == false
            record["onScreenDragDelay"] = computer.touchHoldDuration ?? (preferences.object(forKey: "gesture.holdDuration") as? Double
                ?? RemoteTouchGestureConfiguration.defaultHoldDuration)
            record["useSharedClipboard"] = sharedClipboard && computer.automaticallySharesClipboard != false
            record["allowBellSignal"] = computer.allowsRemoteBell != false
            record["permuteCmdAndCtrlModifierKeys"] = computer.swapsHardwareCommandAndControl == true
            record["enableMomentumScrolling"] = computer.momentumScrolling ?? true
            let display = computer.display(for: .current)
            record["streamVideoAndAudio"] = display.remoteAudio && display.smoothVideo != false
            record["rememberLastSelectedDisplay"] = display.rememberMonitor ?? true
            return record
        }
        let folders: [[String: Any]] = archive.folders.map { name in
            let items = computers.filter { $0.folder == name }.map { $0.id.uuidString }
            let id = UUID.derived(from: "local.nikey.desklink/screens/group/" + name)
            return ["id": id.uuidString, "name": name, "contentType": 8, "items": items, "rawItems": items]
        }
        let result: [String: Any] = ["filename": "Telescope", "screens": screens, "folders": folders, "scFolders": [], "tsFolders": []]
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    enum ExportError: LocalizedError {
        case unknownAuthentication(String), unsupportedSetting(String)
        var errorDescription: String? {
            switch self {
            case .unknownAuthentication(let name):
                "无法确认「\(name)」使用的远程认证类型。请先成功连接这台 Mac，或使用远程随航归档保留当前设置。"
            case .unsupportedSetting(let name):
                "「\(name)」使用了 SSH 密钥。请使用远程随航归档保留这些设置。"
            }
        }
    }
}
