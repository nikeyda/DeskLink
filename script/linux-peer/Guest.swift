import Darwin
import Foundation
import Virtualization

// This test VM has no network adapter, system credentials or shared directories.
// Only the guest's disposable VNC test desktops are forwarded to host loopback.
final class Guest: NSObject, VZVirtualMachineDelegate {
    let root: URL
    let vm: VZVirtualMachine
    var listeners = [DispatchSourceRead]()
    var connections = [UUID: VZVirtioSocketConnection]()

    init(root: URL) throws {
        self.root = root
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = 2
        config.memorySize = 1_536 * 1024 * 1024
        let boot = VZLinuxBootLoader(kernelURL: root.appending(path: "Image"))
        boot.initialRamdiskURL = root.appending(path: "guest-initrd")
        boot.commandLine = "console=hvc0 rdinit=/desklink-init panic=0 quiet"
        config.bootLoader = boot
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: .standardOutput)
        config.serialPorts = [console]
        try config.validate()
        vm = VZVirtualMachine(configuration: config)
        super.init()
        vm.delegate = self
    }

    func start() {
        vm.start { [self] result in
            do {
                try result.get()
                try listen(guestPort: 5901, portFile: "vnc-port")
                try listen(guestPort: 5902, portFile: "tls-port")
                try listen(guestPort: 5903, portFile: "wayland-port")
                try listen(guestPort: 5904, portFile: "resize-port")
            }
            catch { fputs(String(describing: error) + "\n", stderr); exit(1) }
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) { exit(0) }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fputs(error.localizedDescription + "\n", stderr); exit(1)
    }

    private func listen(guestPort: UInt32, portFile: String) throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let port: UInt16 = try withUnsafeMutablePointer(to: &address) { address in
            try address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard Darwin.bind(socket, $0, size) == 0, Darwin.listen(socket, 4) == 0,
                      getsockname(socket, $0, &size) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
                return UInt16(bigEndian: address.pointee.sin_port)
            }
        }
        try String(port).write(to: root.appending(path: portFile), atomically: true, encoding: .utf8)
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .main)
        source.setCancelHandler { Darwin.close(socket) }
        source.setEventHandler { [weak self] in
            let client = accept(socket, nil, nil)
            guard client >= 0 else { return }
            guard let self, let device = vm.socketDevices.first as? VZVirtioSocketDevice else { Darwin.close(client); return }
            device.connect(toPort: guestPort) { [self] result in
                guard case .success(let guest) = result else { Darwin.close(client); return }
                let id = UUID()
                self.connections[id] = guest
                let guestFD = guest.fileDescriptor
                DispatchQueue.global(qos: .utility).async {
                    Self.relay(client, guestFD)
                    Darwin.close(client)
                    DispatchQueue.main.async { self.connections[id] = nil }
                }
            }
        }
        listeners.append(source)
        source.resume()
    }

    private static func relay(_ host: Int32, _ guest: Int32) {
        var pollSet = [pollfd(fd: host, events: Int16(POLLIN), revents: 0), pollfd(fd: guest, events: Int16(POLLIN), revents: 0)]
        var data = [UInt8](repeating: 0, count: 65536)
        while poll(&pollSet, 2, -1) > 0 {
            for i in 0..<2 where pollSet[i].revents != 0 {
                let count = Darwin.read(pollSet[i].fd, &data, data.count)
                guard count > 0 else { return }
                let sent = data.withUnsafeBytes { bytes -> Bool in
                    var used = 0
                    while used < count {
                        let written = Darwin.write(pollSet[1-i].fd, bytes.baseAddress!.advanced(by: used), count - used)
                        guard written > 0 else { return false }
                        used += written
                    }
                    return true
                }
                if !sent { return }
            }
        }
    }
}

signal(SIGPIPE, SIG_IGN)
let root = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
let guest = try Guest(root: root)
DispatchQueue.main.async { guest.start() }
dispatchMain()
