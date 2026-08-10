import Darwin
import Foundation

private let identity = "app.flclashm.client"

private enum UpdateError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let value): return value } }
}

private func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw UpdateError.message("\(executable) failed with status \(process.terminationStatus).")
    }
}

private func startAndConfirmHealthy(_ bundle: URL) throws {
    let executable = bundle.appendingPathComponent("Contents/MacOS/FlClashM")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw UpdateError.message("The replacement application executable is missing.")
    }
    let process = Process()
    process.executableURL = executable
    try process.run()
    // A successful `open` only proves LaunchServices accepted the request. Keep
    // the previous bundle until the new process remains alive through startup.
    for _ in 0..<100 {
        usleep(100_000)
        if !process.isRunning {
            throw UpdateError.message("The replacement application exited during health check.")
        }
    }
}

private func waitForExit(_ pid: pid_t) throws {
    for _ in 0..<300 {
        if kill(pid, 0) != 0 && errno == ESRCH { return }
        usleep(100_000)
    }
    throw UpdateError.message("The running application did not exit.")
}

private func bundleIdentifier(_ bundle: URL) -> String? {
    guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else { return nil }
    return info["CFBundleIdentifier"] as? String
}

private func rejectLinksAndUnexpectedTopLevel(_ root: URL) throws -> URL {
    let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
    let apps = entries.filter { $0.lastPathComponent == "FlClashM.app" }
    guard apps.count == 1,
          entries.allSatisfy({ $0.lastPathComponent == "FlClashM.app" || $0.lastPathComponent == "__MACOSX" }) else {
        throw UpdateError.message("The update archive must contain one FlClashM.app bundle.")
    }
    let bundle = apps[0]
    guard let enumerator = FileManager.default.enumerator(
        at: bundle,
        includingPropertiesForKeys: [.isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
    ) else { throw UpdateError.message("Unable to inspect the staged app bundle.") }
    for case let item as URL in enumerator {
        if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            let resolved = item.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(bundle.standardizedFileURL.path + "/") else {
                throw UpdateError.message("A staged app symbolic link escapes the app bundle.")
            }
        }
    }
    guard bundleIdentifier(bundle) == identity else {
        throw UpdateError.message("The staged app has an unexpected bundle identifier.")
    }
    return bundle
}

private func install(current: URL, archive: URL, parentPID: pid_t) throws {
    guard current.pathExtension == "app", current.lastPathComponent == "FlClashM.app" else {
        throw UpdateError.message("The installed bundle path is unexpected.")
    }
    guard archive.pathExtension.lowercased() == "zip", FileManager.default.fileExists(atPath: archive.path) else {
        throw UpdateError.message("The verified update archive is unavailable.")
    }
    try waitForExit(parentPID)

    let parent = current.deletingLastPathComponent()
    let staging = parent.appendingPathComponent(".FlClashM-update-\(UUID().uuidString)", isDirectory: true)
    let previous = parent.appendingPathComponent(".FlClashM-previous-\(UUID().uuidString).app", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: staging) }
    try run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
    let replacement = try rejectLinksAndUnexpectedTopLevel(staging)

    var movedCurrent = false
    do {
        try FileManager.default.moveItem(at: current, to: previous)
        movedCurrent = true
        try FileManager.default.moveItem(at: replacement, to: current)
        guard bundleIdentifier(current) == identity else {
            throw UpdateError.message("Installed bundle validation failed.")
        }
        try startAndConfirmHealthy(current)
        try FileManager.default.removeItem(at: previous)
    } catch {
        if FileManager.default.fileExists(atPath: current.path) {
            try? FileManager.default.removeItem(at: current)
        }
        if movedCurrent {
            try? FileManager.default.moveItem(at: previous, to: current)
        }
        throw error
    }
}

do {
    if CommandLine.arguments.dropFirst().first == "--self-test" {
        guard bundleIdentifier(URL(fileURLWithPath: "/missing")) == nil else {
            throw UpdateError.message("Updater self-test failed.")
        }
        exit(0)
    }
    guard CommandLine.arguments.count == 4,
          let pid = Int32(CommandLine.arguments[3]) else {
        throw UpdateError.message("Usage: updater-handoff <current.app> <verified.zip> <parent-pid>")
    }
    try install(
        current: URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL,
        archive: URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL,
        parentPID: pid
    )
} catch {
    FileHandle.standardError.write(Data("FlClashM update failed: \(error)\n".utf8))
    exit(1)
}
