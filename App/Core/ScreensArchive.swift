import Foundation
import RFBTransport
import rootshellVNC

private extension FramebufferQuality.Scope {
    init?(screensPolicy: Int) {
        switch screensPolicy {
        case 0: self = .never
        case 1: self = .remoteOnly
        case 2: self = .always
        default: return nil
        }
    }

    var screensPolicy: Int {
        switch self {
        case .never: 0
        case .remoteOnly: 1
        case .always: 2
        }
    }
}

private extension ColorDepth {
    init?(screensColorDepth: Int) {
        switch screensColorDepth {
        case 3: self = .low
        case 1: self = .medium
        case 2: self = .full
        default: return nil
        }
    }

    var screensColorDepth: Int {
        switch self {
        case .low: 3
        case .medium: 1
        case .full: 2
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

    private struct ClientDisplayProfile: Decodable {
        let renderingProtocol: Int?
        let sizingMode: String?
        let selectedVirtualDisplayCount: Int?
        let customWidth: Int?
        let customHeight: Int?
        let useRetina: Bool?

        func apply(to display: inout DesktopDisplayPreferences, for client: DisplayClient) {
            guard renderingProtocol == 1 else { return }
            display.quality = .adaptive
            display.matchWindow = true
            display.retinaResolution = useRetina == false ? false : nil
            guard sizingMode == "custom" else { return }
            if let customWidth, let customHeight {
                let size = DesktopDimensions(width: customWidth, height: customHeight)
                if size.isSupported { display.fixedDesktop = size }
            }
            if selectedVirtualDisplayCount == 2 && (client == .mac || client == .vision) {
                display.layout = .virtualPair
            }
        }
    }

    private struct ClientDisplayProfiles: Decodable {
        let byClient: [String: ClientDisplayProfile]

        init(from decoder: Decoder) throws {
            // The original dictionary has enum keys. Swift's Codable writes
            // alternating keys and values instead of a JSON object for it.
            var container = try decoder.unkeyedContainer()
            var profiles: [String: ClientDisplayProfile] = [:]
            while !container.isAtEnd {
                let family = try container.decode(String.self)
                profiles[family] = try container.decode(ClientDisplayProfile.self)
            }
            byClient = profiles
        }
    }

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
        let colorDepth: Int?
        let adaptiveQualityMode: Int?
        let desktopDisplayPreferences: ClientDisplayProfiles?
        let hardwareKeyboardMode: Int?
        let softwareKeyboardMode: Int?
        let useLegacyKeyboardSystem: Bool?
        let permuteCmdAndCtrlModifierKeys: Bool?
        let showLocalCursor: Bool?
        let useFallbackCursor: Bool?
        let cursorTrackingSpeed: Double?
        let disabledCodecs: [Int32]?
        let imageCompressionMode: Int?
        let tightVncJPEGEncodingQuality: Int?
        let turnOffZooming: Bool?
        let initialScalingMode: Int?
        let onScreenDragDelay: TimeInterval?
        let pcScrollSpeed: Int?
        let startInObserveMode: Bool
        let useCurtainMode: Bool?
        let curtainModeMessage: String?
        let onDisconnectAction: Int
        let grabScreenshot: Bool?
        let useSharedClipboard: Bool
        let allowBellSignal: Bool?
        let enableMomentumScrolling: Bool?
        let rememberLastSelectedDisplay: Bool?
        let streamVideoAndAudio: Bool?
        let useSecureConnection: Bool
        let useSecureConnectionsLocally: Bool?
        let sshHostname: String?
        let sshPort: UInt16?
        let sshUsers: [User]?

        func computer() throws -> Computer {
            guard version == 6, clientProtocol == "vnc", ([1, 2, 3].contains(authenticationMethod) || (authenticationMethod == 5 && operatingSystem == 5)),
                  users.count <= 1 else {
                throw ImportError.unsupportedConnection
            }
            let host = try Endpoint.hostOnly(hostname)
            var result = Computer(name: name ?? "", endpoint: try Endpoint(address: host, defaultPort: port))
            result.id = id
            result.savesDisconnectScreenshot = grabScreenshot == true ? true : nil
            result.curtainsDisplayOnConnect = useCurtainMode == true ? true : nil
            result.curtainMessage = curtainModeMessage.flatMap { $0.isEmpty ? nil : $0 }
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
            if let mode = DesktopAuthentication(rawValue: authenticationMethod), mode == .vncPassword || mode == .unauthenticated {
                result.authentication = mode
            }
            let depth = colorDepth.flatMap(ColorDepth.init(screensColorDepth:))
            result.colorDepth = depth == .full ? nil : depth
            result.swapsHardwareCommandAndControl = permuteCmdAndCtrlModifierKeys == true ? true : nil
            result.showsLocalCursor = showLocalCursor
            result.usesFallbackCursor = useFallbackCursor == true ? true : nil
            result.cursorTrackingSpeed = CursorTrackingSpeed.validated(cursorTrackingSpeed)
            if let disabledCodecs, !disabledCodecs.isEmpty {
                result.disabledVNCCodecs = Set(disabledCodecs).sorted()
            }
            var framebuffer = FramebufferQuality()
            if let mode = adaptiveQualityMode, let adaptive = FramebufferQuality.Scope(screensPolicy: mode) {
                framebuffer.adaptive = adaptive
            }
            if let mode = imageCompressionMode, let compression = FramebufferQuality.Scope(screensPolicy: mode) {
                framebuffer.compression = compression
            }
            if let quality = tightVncJPEGEncodingQuality, FramebufferQuality.tightJPEGQualityRange.contains(quality),
               quality != FramebufferQuality.defaultTightJPEGQuality {
                framebuffer.tightJPEGQuality = quality
            }
            result.framebufferQuality = framebuffer == FramebufferQuality() ? nil : framebuffer
            result.allowsViewportZoom = turnOffZooming == true ? false : nil
            if let initialScalingMode, initialScalingMode != RemoteViewportSizing.fit.rawValue {
                result.initialViewportSizing = RemoteViewportSizing(rawValue: initialScalingMode)
            }
            result.touchHoldDuration = onScreenDragDelay
            if let pcScrollSpeed {
                guard let speed = RemoteScrollSpeed.allCases.first(where: { $0.screensPosition == pcScrollSpeed }) else {
                    throw ImportError.unsupportedConnection
                }
                result.pcScrollSpeed = speed == .standard ? nil : speed
            }
            let oldMode: DesktopKeyboardMode? = useLegacyKeyboardSystem == true ? .legacy : nil
            let hardwareDefault: DesktopKeyboardMode = operatingSystem == 1 ? .keystrokes : .unicode
            let hardware = hardwareKeyboardMode.flatMap(DesktopKeyboardMode.init(rawValue:)) ?? oldMode ?? hardwareDefault
            result.hardwareKeyboardMode = hardware == .keystrokes && operatingSystem != 1 ? .unicode : hardware
            result.softwareKeyboardMode = softwareKeyboardMode.flatMap(DesktopKeyboardMode.init(rawValue:)) ?? oldMode
            result.viewOnly = startInObserveMode
            // The application-wide clipboard preference still applies when sharing was permitted.
            result.automaticallySharesClipboard = useSharedClipboard
            result.allowsRemoteBell = allowBellSignal == false ? false : nil
            result.momentumScrolling = enableMomentumScrolling
            if let media = streamVideoAndAudio, !media {
                result.remoteAudio = false
                result.smoothVideo = false
            }
            let commonDisplay = result.display(for: .mac)
            for client in DisplayClient.allCases {
                var display = commonDisplay
                let profile = desktopDisplayPreferences?.byClient[client.rawValue]
                profile?.apply(to: &display, for: client)
                display.rememberMonitor = rememberLastSelectedDisplay
                result.setDisplay(display, for: client, explicit: profile != nil)
            }
            if useSecureConnection {
                let names = sshUsers ?? []
                guard names.count <= 1 else { throw ImportError.unsupportedConnection }
                let username = names.first?.username.flatMap { $0.isEmpty ? nil : $0 } ?? result.username
                guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let sshPort, sshPort > 0 else { throw ImportError.incompleteSSH }
                let server = try sshHostname.flatMap { $0.isEmpty ? nil : try Endpoint.hostOnly($0) }
                result.ssh = SSHSettings(port: sshPort, username: username, server: server,
                                         secureLocally: useSecureConnectionsLocally == false ? false : nil)
            }
            return result
        }
    }

    private let screens: [Screen]
    private let folders: [Folder]
    private let tsFolders: [ScreensDirectoryFolder]?
    private let scFolders: [ScreensDirectoryFolder]?

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
        let directories = ScreensDirectoryFolders(tailscale: source.tsFolders ?? [], screensConnect: source.scFolders ?? [])
        guard directories.isValid else { throw ImportError.unsupportedFolder }
        var result = LibraryArchive()
        if directories.count > 0 { result.screensDirectoryFolders = directories }
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
    @MainActor static func export(_ archive: LibraryArchive, knownMacs: Set<UUID>, sharedClipboard: Bool,
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
                system = computer.screensOperatingSystem ?? 6
                authentication = DesktopAuthentication.vncPassword.rawValue
            } else { throw ExportError.unknownAuthentication(computer.displayName) }
            guard ![2, 3].contains(authentication) || computer.username.isEmpty else {
                throw ExportError.unknownAuthentication(computer.displayName)
            }
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
            let hardware = computer.hardwareKeyboardMode
            record["hardwareKeyboardMode"] = (system != 1 && hardware == .keystrokes ? .unicode : hardware).rawValue
            record["softwareKeyboardMode"] = (computer.softwareKeyboardMode ?? .unicode).rawValue
            func user(_ name: String?, role: String) -> [String: Any] {
                let identity = "local.nikey.desklink/screens/" + id + "/" + role + "/" + (name ?? "")
                var entry: [String: Any] = ["id": UUID.derived(from: identity).uuidString, "username": NSNull()]
                if let name, !name.isEmpty { entry["username"] = name }
                return entry
            }
            record["users"] = authentication == DesktopAuthentication.unauthenticated.rawValue
                ? [] : [user(computer.username, role: "desktop")]
            record["useSecureConnection"] = computer.ssh != nil
            record["useSecureConnectionsLocally"] = computer.ssh?.secureLocally != false
            record["sshHostname"] = computer.ssh?.server
            record["sshPort"] = Int(computer.ssh?.port ?? 22)
            record["sshUsers"] = [user(computer.ssh?.username, role: "ssh")]
            record["onDisconnectAction"] = computer.disconnectAction?.screensArchiveValue ?? 0
            record["grabScreenshot"] = computer.savesDisconnectScreenshot == true
            record["pcScrollSpeed"] = (computer.pcScrollSpeed ?? .standard).screensPosition
            record["startInObserveMode"] = computer.viewOnly
            record["useCurtainMode"] = computer.curtainsDisplayOnConnect == true
            record["curtainModeMessage"] = computer.curtainMessage ?? ""
            record["showLocalCursor"] = computer.showsLocalCursor ?? (preferences.object(forKey: "connection.clientCursor") as? Bool ?? true)
            record["useFallbackCursor"] = computer.usesFallbackCursor == true
            if let speed = CursorTrackingSpeed.validated(computer.cursorTrackingSpeed) { record["cursorTrackingSpeed"] = speed }
            record["disabledCodecs"] = computer.disabledVNCCodecs ?? []
            let display = computer.display(for: .current)
            let framebuffer = computer.framebufferQuality ?? FramebufferQuality()
            record["colorDepth"] = (display.colorDepth ?? .full).screensColorDepth
            record["adaptiveQualityMode"] = display.quality == .lossless ? 0 : framebuffer.adaptive.screensPolicy
            record["imageCompressionMode"] = display.quality == .lossless ? 0 : framebuffer.compression.screensPolicy
            record["tightVncJPEGEncodingQuality"] = framebuffer.resolvedTightJPEGQuality
            record["turnOffZooming"] = computer.allowsViewportZoom == false
            record["initialScalingMode"] = (computer.initialViewportSizing ?? .fit).rawValue
            record["onScreenDragDelay"] = computer.touchHoldDuration ?? (preferences.object(forKey: "gesture.holdDuration") as? Double
                ?? RemoteTouchGestureConfiguration.defaultHoldDuration)
            record["useSharedClipboard"] = computer.sharesClipboard(defaultValue: sharedClipboard)
            record["allowBellSignal"] = computer.allowsRemoteBell != false
            record["permuteCmdAndCtrlModifierKeys"] = computer.swapsHardwareCommandAndControl == true
            record["enableMomentumScrolling"] = computer.momentumScrolling ?? true
            record["streamVideoAndAudio"] = display.remoteAudio && display.smoothVideo != false
            record["rememberLastSelectedDisplay"] = display.rememberMonitor ?? true
            record["desktopDisplayPreferences"] = encodedDisplayProfiles(for: computer)
            return record
        }
        let folders: [[String: Any]] = archive.folders.map { name in
            let items = computers.filter { $0.folder == name }.map { $0.id.uuidString }
            let id = UUID.derived(from: "local.nikey.desklink/screens/group/" + name)
            return ["id": id.uuidString, "name": name, "contentType": 8, "items": items, "rawItems": items]
        }
        func directoryRecords(_ entries: [ScreensDirectoryFolder]) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries))
        }
        let result: [String: Any] = [
            "filename": "Telescope", "screens": screens, "folders": folders,
            "scFolders": try directoryRecords(archive.screensDirectoryFolders?.screensConnect ?? []),
            "tsFolders": try directoryRecords(archive.screensDirectoryFolders?.tailscale ?? []),
        ]
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    private static func encodedDisplayProfiles(for computer: Computer) -> [Any] {
        DisplayClient.allCases.flatMap { client -> [Any] in
            let display = computer.display(for: client).resolved(for: client)
            guard display.quality == .adaptive || computer.deviceDisplays?[client.rawValue] != nil else { return [] }
            let size = display.fixedDesktop.flatMap { $0.isSupported ? $0 : nil }
            let defaults = DesktopDimensions.standard
            let profile: [String: Any] = [
                "renderingProtocol": display.quality == .adaptive ? 1 : 0,
                "hasChosenRenderingProtocol": true,
                "sizingMode": size == nil ? "dynamic" : "custom",
                "selectedVirtualDisplayCount": display.layout == .virtualPair ? 2 : 1,
                "customWidth": (size ?? defaults).width,
                "customHeight": (size ?? defaults).height,
                "useRetina": display.retinaResolution ?? true,
            ]
            return [client.rawValue, profile]
        }
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
