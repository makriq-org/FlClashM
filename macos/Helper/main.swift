import Darwin
import Foundation

private let identity = "app.flclashm.client"
private let protocolVersion = 1
private let socketPath = "/var/run/\(identity).helper.sock"
private let statePath = "/var/db/\(identity).helper-state.json"
private let routeTransaction = "app-session-route"
private let dnsTransaction = "app-session-dns"
private var helperBuild = ""

private struct SavedState: Codable {
    var interface: String?
    var routes: [String] = []
    var dnsService: String?
    var dnsServers: [String]?
}

private enum HelperError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let value): return value }
    }
}

private func run(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if process.terminationStatus != 0 && !allowFailure {
        throw HelperError.message("\(executable) failed: \(text)")
    }
    return text
}

private func validInterface(_ value: Any?) -> String? {
    guard let value = value as? String,
          value.range(of: "^[A-Za-z][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil else { return nil }
    return value
}

private func resolveRuntimeInterface(_ requested: String) throws -> String {
    guard requested == "FlClashM" else {
        throw HelperError.message("Only the bundled runtime interface identity is allowed.")
    }
    let output = try run("/sbin/ifconfig", [])
    var current: String?
    var matches: [String] = []
    for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
        if let first = line.first, !first.isWhitespace, let colon = line.firstIndex(of: ":") {
            current = String(line[..<colon])
            continue
        }
        if let current, current.range(of: "^utun[0-9]+$", options: .regularExpression) != nil,
           line.trimmingCharacters(in: .whitespaces).hasPrefix("inet 198.18.0.1 ") {
            matches.append(current)
        }
    }
    let unique = Array(Set(matches))
    guard unique.count == 1 else {
        throw HelperError.message("Unable to identify one FlClashM utun interface.")
    }
    return unique[0]
}

private func validTransaction(_ value: Any?, expected: String) -> Bool {
    (value as? String) == expected
}

private func validCIDR(_ value: String) -> Bool {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let prefix = Int(parts[1]) else { return false }
    var address4 = in_addr()
    var address6 = in6_addr()
    if inet_pton(AF_INET, String(parts[0]), &address4) == 1 { return (0...32).contains(prefix) }
    if inet_pton(AF_INET6, String(parts[0]), &address6) == 1 { return (0...128).contains(prefix) }
    return false
}

private func validIP(_ value: String) -> Bool {
    var address4 = in_addr()
    var address6 = in6_addr()
    return inet_pton(AF_INET, value, &address4) == 1 || inet_pton(AF_INET6, value, &address6) == 1
}

private func loadState() -> SavedState {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
          let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return SavedState() }
    return state
}

private func saveState(_ state: SavedState) throws {
    let data = try JSONEncoder().encode(state)
    try data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    chmod(statePath, 0o600)
}

private func defaultNetworkService() throws -> String {
    let route = try run("/sbin/route", ["-n", "get", "default"])
    guard let line = route.split(separator: "\n").first(where: { $0.contains("interface:") }),
          let device = line.split(separator: " ").last else {
        throw HelperError.message("Unable to resolve the default interface.")
    }
    let services = try run("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
    let blocks = services.components(separatedBy: "\n\n")
    guard let block = blocks.first(where: { $0.contains("Device: \(device)") }),
          let first = block.split(separator: "\n").first else {
        throw HelperError.message("Unable to resolve the default network service.")
    }
    let name = first.replacingOccurrences(of: "^\\(\\d+\\)\\s*", with: "", options: .regularExpression)
    guard !name.isEmpty else { throw HelperError.message("Invalid network service.") }
    return name
}

@discardableResult
private func rollback(_ state: inout SavedState) -> Bool {
    var pending = state
    var complete = true
    if let service = state.dnsService, let servers = state.dnsServers {
        let args = ["-setdnsservers", service] + (servers.isEmpty ? ["Empty"] : servers)
        do {
            _ = try run("/usr/sbin/networksetup", args)
            pending.dnsService = nil
            pending.dnsServers = nil
        } catch {
            complete = false
        }
    }
    if let interface = state.interface {
        var remaining: [String] = []
        for route in state.routes.reversed() {
            do {
                _ = try run("/sbin/route", ["-n", "delete", "-net", route, "-interface", interface])
            } catch {
                remaining.append(route)
                complete = false
            }
        }
        pending.routes = Array(remaining.reversed())
        if pending.routes.isEmpty {
            do {
                _ = try run("/sbin/ifconfig", [interface, "down"])
                pending.interface = nil
            } catch {
                complete = false
            }
        }
    }
    if complete, pending.interface == nil, pending.routes.isEmpty,
       pending.dnsService == nil, pending.dnsServers == nil {
        do {
            if FileManager.default.fileExists(atPath: statePath) {
                try FileManager.default.removeItem(atPath: statePath)
            }
            state = SavedState()
            return true
        } catch {
            // Keep a durable record if the state file cannot be removed.
            complete = false
        }
    }
    state = pending
    try? saveState(pending)
    return false
}

private func response(state: String, message: String = "") -> Data {
    let value: [String: Any] = ["state": state, "message": message]
    let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{\"state\":\"failed\"}".utf8)
    return data + Data([0x0a])
}

private func handle(_ request: [String: Any], state: inout SavedState) throws -> Data {
    guard request["protocolVersion"] as? Int == protocolVersion else {
        throw HelperError.message("Unsupported helper protocol version.")
    }
    guard request["installIdentity"] as? String == identity else {
        throw HelperError.message("Unexpected install identity.")
    }
    guard let operation = request["operation"] as? String,
          let parameters = request["parameters"] as? [String: Any] else {
        throw HelperError.message("Invalid helper request.")
    }
    if request["runtimeArtifact"] != nil || parameters.keys.contains(where: {
        let key = $0.lowercased()
        return key.contains("path") || key.contains("command") || key.contains("argument") || key.contains("environment") || key.contains("shell")
    }) {
        throw HelperError.message("Executable paths and arguments are forbidden.")
    }

    switch operation {
    case "tunOpen":
        guard Set(parameters.keys) == Set(["interface", "mtu"]),
              let interface = validInterface(parameters["interface"]),
              let mtu = parameters["mtu"] as? Int, (576...65535).contains(mtu) else {
            throw HelperError.message("Invalid tunOpen request.")
        }
        let runtimeInterface = try resolveRuntimeInterface(interface)
        _ = try run("/sbin/ifconfig", [runtimeInterface, "mtu", String(mtu), "up"])
        state.interface = runtimeInterface
        try saveState(state)
    case "tunClose":
        guard Set(parameters.keys) == Set(["interface"]), let interface = validInterface(parameters["interface"]) else {
            throw HelperError.message("Invalid tunClose request.")
        }
        guard interface == "FlClashM" else {
            throw HelperError.message("Invalid runtime interface identity.")
        }
        guard rollback(&state) else {
            throw HelperError.message("Unable to fully roll back the TUN session.")
        }
    case "routeApply":
        guard Set(parameters.keys) == Set(["interface", "routes"]),
              let interface = validInterface(parameters["interface"]),
              let routes = parameters["routes"] as? [String], !routes.isEmpty, routes.count <= 128,
              routes.allSatisfy(validCIDR) else { throw HelperError.message("Invalid routeApply request.") }
        guard interface == "FlClashM", let runtimeInterface = state.interface else {
            throw HelperError.message("The bundled TUN session is not active.")
        }
        if !state.routes.isEmpty { throw HelperError.message("Routes are already active.") }
        do {
            for route in routes {
                _ = try run("/sbin/route", ["-n", "add", "-net", route, "-interface", runtimeInterface])
                state.routes.append(route)
                try saveState(state)
            }
        } catch {
            rollback(&state)
            throw error
        }
    case "routeRollback":
        guard Set(parameters.keys) == Set(["transaction"]), validTransaction(parameters["transaction"], expected: routeTransaction) else {
            throw HelperError.message("Invalid route rollback transaction.")
        }
        guard rollback(&state) else {
            throw HelperError.message("Unable to fully roll back network routes.")
        }
    case "dnsApply":
        guard Set(parameters.keys) == Set(["interface", "servers"]), validInterface(parameters["interface"]) == "FlClashM",
              let servers = parameters["servers"] as? [String], !servers.isEmpty, servers.count <= 16,
              servers.allSatisfy(validIP) else { throw HelperError.message("Invalid dnsApply request.") }
        if state.dnsService != nil { return response(state: "ready") }
        let service = try defaultNetworkService()
        let existing = try run("/usr/sbin/networksetup", ["-getdnsservers", service])
        let previous = existing.hasPrefix("There aren't any DNS Servers set on") ? [] : existing.split(separator: "\n").map(String.init)
        state.dnsService = service
        state.dnsServers = previous
        try saveState(state)
        do { _ = try run("/usr/sbin/networksetup", ["-setdnsservers", service] + servers) }
        catch { rollback(&state); throw error }
    case "dnsRollback":
        guard Set(parameters.keys) == Set(["transaction"]), validTransaction(parameters["transaction"], expected: dnsTransaction) else {
            throw HelperError.message("Invalid DNS rollback transaction.")
        }
        guard rollback(&state) else {
            throw HelperError.message("Unable to fully roll back DNS.")
        }
    case "runtimeStart", "runtimeStop":
        throw HelperError.message("Runtime processes must remain unprivileged on macOS.")
    default:
        throw HelperError.message("Unsupported helper operation.")
    }
    return response(state: "ready")
}

private func consoleUID() -> uid_t? {
    let value = try? run("/usr/bin/stat", ["-f", "%u", "/dev/console"])
    guard let text = value, let uid = UInt32(text) else { return nil }
    return uid
}

private func readLine(_ descriptor: Int32) -> Data? {
    var data = Data()
    var byte: UInt8 = 0
    while data.count <= 65_536 {
        let count = Darwin.read(descriptor, &byte, 1)
        if count <= 0 { return nil }
        if byte == 0x0a { return data }
        data.append(byte)
    }
    return nil
}

private func serveClient(_ client: Int32, state: inout SavedState) {
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    guard getpeereid(client, &peerUID, &peerGID) == 0,
          peerUID != 0, peerUID == consoleUID() else { return }
    let hello: [String: Any] = ["state": "ready", "message": "", "protocolVersion": protocolVersion, "installIdentity": identity, "helperBuild": helperBuild]
    let helloData = (try? JSONSerialization.data(withJSONObject: hello)) ?? Data()
    _ = (helloData + Data([0x0a])).withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
    while true {
        var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&descriptor, 1, 1_000)
        if pollResult == 0 {
            if let interface = state.interface,
               (try? run("/sbin/ifconfig", [interface])) == nil {
                rollback(&state)
            }
            continue
        }
        if pollResult < 0 || descriptor.revents & Int16(POLLHUP | POLLERR) != 0 { break }
        guard let line = readLine(client) else { break }
        let output: Data
        do {
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw HelperError.message("Invalid JSON request.")
            }
            output = try handle(object, state: &state)
        } catch {
            output = response(state: "failed", message: String(describing: error))
        }
        _ = output.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
    }
}

private func serve() throws {
    guard geteuid() == 0 else { throw HelperError.message("The helper must run as root.") }
    var stale = loadState()
    rollback(&stale)
    unlink(socketPath)
    let server = socket(AF_UNIX, SOCK_STREAM, 0)
    guard server >= 0 else { throw HelperError.message("Unable to create helper socket.") }
    defer { close(server); unlink(socketPath) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw HelperError.message("Helper socket path is too long.")
    }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        socketPath.withCString { source in strcpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source) }
    }
    let bindResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bindResult == 0 else { throw HelperError.message("Unable to bind helper socket: \(errno).") }
    guard let owner = consoleUID() else {
        throw HelperError.message("Unable to resolve the console user for helper IPC.")
    }
    guard chown(socketPath, owner, 0) == 0, chmod(socketPath, 0o600) == 0 else {
        throw HelperError.message("Unable to protect the helper socket.")
    }
    guard listen(server, 4) == 0 else { throw HelperError.message("Unable to listen on helper socket.") }
    var state = SavedState()
    while true {
        let client = accept(server, nil, nil)
        if client < 0 { continue }
        serveClient(client, state: &state)
        close(client)
        rollback(&state)
    }
}

private func clientSmoke() throws {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw HelperError.message("Unable to create smoke socket.") }
    defer { close(descriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        socketPath.withCString { source in strcpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source) }
    }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0, let hello = readLine(descriptor),
          let json = try JSONSerialization.jsonObject(with: hello) as? [String: Any],
          json["protocolVersion"] as? Int == protocolVersion,
          json["installIdentity"] as? String == identity else {
        throw HelperError.message("Helper smoke handshake failed.")
    }
}

do {
    switch CommandLine.arguments.dropFirst().first {
    case "--serve":
        guard CommandLine.arguments.count == 4, CommandLine.arguments[2] == "--build",
              !CommandLine.arguments[3].isEmpty else {
            throw HelperError.message("Expected a helper build identity.")
        }
        helperBuild = CommandLine.arguments[3]
        try serve()
    case "--rollback-all":
        guard geteuid() == 0 else { throw HelperError.message("Cleanup must run as root.") }
        var state = loadState()
        guard rollback(&state) else { throw HelperError.message("Cleanup is incomplete; retained rollback state.") }
    case "--client-smoke": try clientSmoke()
    case "--self-test":
        guard validInterface("FlClashM") != nil, validCIDR("0.0.0.0/1"), validIP("1.1.1.1") else {
            throw HelperError.message("Helper validation self-test failed.")
        }
    default: throw HelperError.message("Expected --serve, --rollback-all, --client-smoke or --self-test.")
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
