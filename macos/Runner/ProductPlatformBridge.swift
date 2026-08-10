import Cocoa
import Darwin
import FlutterMacOS

final class ProductPlatformBridge {
    private static let identity = "app.flclashm.client"
    private static let protocolVersion = 1
    private static let socketPath = "/var/run/\(identity).helper.sock"

    private var descriptor: Int32 = -1
    private let lock = NSLock()

    func register(with controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: "\(Self.identity)/privileged-helper",
            binaryMessenger: controller.engine.binaryMessenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { result(false); return }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let value: Any
                    switch call.method {
                    case "status": value = try self.ensureConnected()
                    case "install": value = try self.runInstaller(action: "install") && self.ensureConnected()
                    case "uninstall":
                        self.disconnect()
                        value = try self.runInstaller(action: "uninstall")
                    case "request":
                        guard let request = call.arguments as? [String: Any] else {
                            throw BridgeError.message("Invalid helper request arguments.")
                        }
                        value = try self.send(request)
                    case "installUpdate":
                        guard let arguments = call.arguments as? [String: Any],
                              let packagePath = arguments["packagePath"] as? String else {
                            throw BridgeError.message("Missing verified update path.")
                        }
                        value = try self.startUpdater(packagePath: packagePath)
                    default:
                        DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
                        return
                    }
                    DispatchQueue.main.async { result(value) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "MACOS_PLATFORM_BRIDGE", message: String(describing: error), details: nil))
                    }
                }
            }
        }
    }

    func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }

    private func ensureConnected() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 { return true }
        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            Self.socketPath.withCString { source in
                strcpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source)
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { Darwin.close(socketDescriptor); return false }
        descriptor = socketDescriptor
        guard let hello = try readJSON(),
              hello["state"] as? String == "ready",
              hello["protocolVersion"] as? Int == Self.protocolVersion,
              hello["installIdentity"] as? String == Self.identity else {
            Darwin.close(descriptor); descriptor = -1
            throw BridgeError.message("The installed helper is incompatible with this app.")
        }
        return true
    }

    private func send(_ request: [String: Any]) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        if descriptor < 0 {
            lock.unlock()
            let ready = try ensureConnected()
            lock.lock()
            guard ready else { throw BridgeError.message("The privileged helper is not installed.") }
        }
        let payload = try JSONSerialization.data(withJSONObject: request) + Data([0x0a])
        let count = payload.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count == payload.count, let response = try readJSON() else {
            Darwin.close(descriptor); descriptor = -1
            throw BridgeError.message("The helper connection closed unexpectedly.")
        }
        return response
    }

    private func readJSON() throws -> [String: Any]? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count <= 65_536 {
            let count = Darwin.read(descriptor, &byte, 1)
            if count <= 0 { return nil }
            if byte == 0x0a {
                return try JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            data.append(byte)
        }
        throw BridgeError.message("The helper response exceeded the size limit.")
    }

    private func runInstaller(action: String) throws -> Bool {
        guard action == "install" || action == "uninstall" else { return false }
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard bundle.path.hasPrefix("/Applications/"), Bundle.main.bundleIdentifier == Self.identity else {
            throw BridgeError.message("Move FlClashM.app to /Applications before installing the helper.")
        }
        let script = bundle.appendingPathComponent("Contents/Resources/helper/install-helper.sh").path
        guard FileManager.default.isExecutableFile(atPath: script) else {
            throw BridgeError.message("The helper installer is missing from the app bundle.")
        }
        let command = "/bin/sh \(shellQuote(script)) \(action)"
        let source = "do shell script \(appleScriptQuote(command)) with administrator privileges"
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if output == nil || error != nil {
            throw BridgeError.message(error?[NSAppleScript.errorMessage] as? String ?? "Administrator action was cancelled.")
        }
        return true
    }

    private func startUpdater(packagePath: String) throws -> Bool {
        let archive = URL(fileURLWithPath: packagePath).standardizedFileURL
        guard archive.pathExtension.lowercased() == "zip",
              archive.path.hasPrefix(FileManager.default.temporaryDirectory.deletingLastPathComponent().path) ||
                archive.path.hasPrefix(NSHomeDirectory()) else {
            throw BridgeError.message("The verified update archive path is invalid.")
        }
        let updater = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/updater-handoff")
        guard FileManager.default.isExecutableFile(atPath: updater.path) else {
            throw BridgeError.message("The update handoff is missing from the app bundle.")
        }
        disconnect()
        let process = Process()
        process.executableURL = updater
        process.arguments = [Bundle.main.bundlePath, archive.path, String(getpid())]
        try process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Darwin.exit(0) }
        return true
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

private enum BridgeError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let value): return value } }
}
