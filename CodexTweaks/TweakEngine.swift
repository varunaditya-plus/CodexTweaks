import AppKit
import Foundation

struct TweakError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// LAST UOPDATED CODEX VERSION: 26.1103

// Codex sidebar assignments (projects, pins, chat-to-project assignments) are in ~/.codex/.codex-global-state.json
// While "electron-account-renderer-state-v1" exists, the sidebar belongs to its "owner" ChatGPT account
// Other accounts' sidebars are saved under "inactive" and swapped in when the account changes.
// Owner is decoded from the ChatGPT token, so an API key has a null owner and starts with an empty sidebar.

// Without that wrapper Codex treats the sidebar as shared, and never re-creates it at launch or in API-key mode.
// Only an in-app sign-out or ChatGPT account switch re-creates it.
// This merges every copy into one shared sidebar and removes the wrapper, only while Codex is closed.
// Codex app bundle is never modified, and the state file is backed up before every change.

final class TweakEngine {
    static let codexBundleID = "com.openai.codex"
    private static let accountStateKey = "electron-account-renderer-state-v1"
    private static let atomsKey = "electron-persisted-atom-state"
    private static let cliInApp = "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    private static let backupsToKeep = 10

    let home: URL
    private let fm = FileManager.default

    init() {
        let custom = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? ""
        home = custom.isEmpty ? fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex") : URL(fileURLWithPath: custom)
    }

    var stateFile: URL { home.appendingPathComponent(".codex-global-state.json") }
    var stateBackupFile: URL { home.appendingPathComponent(".codex-global-state.json.bak") }
    var authFile: URL { home.appendingPathComponent("auth.json") }
    var backupRoot: URL { home.appendingPathComponent("codextweaks-backups") }

    var codexInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.codexBundleID) != nil
    }

    // "apikey", "chatgpt", or nil when signed out.
    func authMode() -> String? {
        guard let data = try? Data(contentsOf: authFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["auth_mode"] as? String
    }

    // Actions:

    func applyAPIKey(_ apiKey: String, log: (String) -> Void) async throws {
        try await whileCodexClosed(log: log) {
            try combineSidebar(log: log)
            try runCLI(["login", "--with-api-key"], stdin: apiKey + "\n")
            guard authMode() == "apikey" else { throw TweakError("Codex didn't accept the API key.") }
            log("Codex now uses your API key.")
        }
    }

    // Codex reopens on its sign-in screen, and the shared sidebar is kept when you sign in there.
    func switchToOpenAIAccount(log: (String) -> Void) async throws {
        try await whileCodexClosed(log: log) {
            try combineSidebar(log: log)
            try runCLI(["logout"])
            guard authMode() == nil else { throw TweakError("Codex is still signed in.") }
            log("Signed out of your API key. Sign in with your OpenAI account in Codex.")
        }
    }

    func combineSidebarAndRestart(log: (String) -> Void) async throws {
        try await whileCodexClosed(log: log) { try combineSidebar(log: log) }
    }

    func combineIfSplit(log: (String) -> Void) throws {
        guard !codexAppRunning(), sidebarIsSplit() else { return }
        try combineSidebar(log: log)
    }

    // Sidebar checks:

    // True after an in-app sign-out or account switch made Codex tie the sidebar to an account again.
    func sidebarIsSplit() -> Bool {
        (try? loadState())?[Self.accountStateKey] != nil
    }

    static let unknownFormatMessage =
        "Codex changed how it stores accounts, so Codex Tweaks left your sidebar untouched. It needs an update for this Codex version."

    // A newer Codex may rename the wrapper key, which would otherwise make the tweak silently do nothing.
    func hasUnknownAccountFormat() -> Bool {
        guard let state = try? loadState() else { return false }
        return state.keys.contains { $0.hasPrefix("electron-account-renderer-state") && $0 != Self.accountStateKey }
    }

    func stateModificationDate() -> Date? {
        (try? fm.attributesOfItem(atPath: stateFile.path))?[.modificationDate] as? Date
    }

    // Codex process:

    // Only the app's main process writes the state file; its app-server keeps running after the window quits.
    func codexAppRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexBundleID)
            .contains { !$0.isTerminated }
    }

    private func whileCodexClosed(log: (String) -> Void, _ body: () throws -> Void) async throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexBundleID)
        if !apps.isEmpty {
            log("Quitting Codex…")
            apps.forEach { $0.terminate() }
            // Give Codex up to 20 seconds to save and quit.
            for _ in 0..<40 where codexAppRunning() {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            if codexAppRunning() { throw TweakError("Codex didn't quit. Close it and try again.") }
        }
        // The app-server caches the sign-in, so stop it and let the next launch start one that reads the new auth.json.
        for pid in appServerProcessIDs() { kill(pid, SIGTERM) }
        // Reopen Codex even if body throws.
        defer { launchCodex() }
        try body()
    }

    // Matches only app-servers started by Codex Desktop, not CLI sessions you run yourself.
    private func appServerProcessIDs() -> [pid_t] {
        let ps = run("/bin/ps", ["-axo", "pid=,command="]).output
        return ps.split(separator: "\n").compactMap { line in
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard fields.count == 2, let pid = pid_t(fields[0]) else { return nil }
            let command = fields[1]
            let ownedByApp = command.contains("/.codex/packages/app-server-daemon/") || command.contains(Self.cliInApp)
            return ownedByApp && command.contains(" app-server") ? pid : nil
        }
    }

    private func launchCodex() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.codexBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // Codex CLI:

    private func runCLI(_ args: [String], stdin: String? = nil) throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.codexBundleID) else {
            throw TweakError("Couldn't find the Codex app.")
        }
        let cli = app.appendingPathComponent(Self.cliInApp).path
        guard fm.isExecutableFile(atPath: cli) else { throw TweakError("Couldn't find Codex's command line tool.") }
        let result = run(cli, args, stdin: stdin)
        guard result.status == 0 else {
            throw TweakError("codex \(args[0]) failed: \(result.output.suffix(300))")
        }
    }

    // The API key is passed on stdin so it never appears in the process list.
    private func run(_ path: String, _ args: [String], stdin: String? = nil) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let input = Pipe()
        if stdin != nil { process.standardInput = input }
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // Sidebar merge:

    // Same fallback as Codex: the .bak is only used when the main file is unreadable.
    private func loadState() throws -> [String: Any] {
        for file in [stateFile, stateBackupFile] {
            if let data = try? Data(contentsOf: file),
               let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return state
            }
        }
        throw TweakError("Couldn't read Codex's sidebar file.")
    }

    func combineSidebar(log: (String) -> Void) throws {
        guard var state = try? loadState(), let rawWrapper = state[Self.accountStateKey] else { return }
        
        // Only edit the exact format this Codex version uses: an owner (string or null) and saved copies of atoms and globals.
        // Anything else is left untouched.
        guard let wrapper = rawWrapper as? [String: Any],
              wrapper["owner"] is String || wrapper["owner"] is NSNull,
              let inactive = wrapper["inactive"] as? [String: Any],
              inactive.values.allSatisfy({ ($0 as? [String: Any])?["atoms"] is [String: Any] && ($0 as? [String: Any])?["globals"] is [String: Any] })
        else { throw TweakError(Self.unknownFormatMessage) }
        try backupState(log: log)

        // Saved copies are older than the active one, so they merge first and the active copy wins conflicts.
        // Among saved copies, smaller ones merge first so the fullest copy wins conflicts.
        let saved = inactive.values.compactMap { $0 as? [String: Any] }.sorted { size($0) < size($1) }
        var atoms: [String: Any] = [:]
        var globals: [String: Any] = [:]
        for copy in saved {
            for (key, value) in copy["atoms"] as? [String: Any] ?? [:] { atoms[key] = combine(atoms[key], value) }
            for (key, value) in copy["globals"] as? [String: Any] ?? [:] { globals[key] = combine(globals[key], value) }
        }

        for (key, value) in state[Self.atomsKey] as? [String: Any] ?? [:] { atoms[key] = combine(atoms[key], value) }
        state[Self.atomsKey] = atoms
        for (key, value) in globals { state[key] = combine(value, state[key]) }
        if !saved.isEmpty { log("Combined \(saved.count + 1) copies of your sidebar.") }
        state.removeValue(forKey: Self.accountStateKey)

        // Write both files like Codex does, so its .bak fallback never brings back the old wrapper.
        let data = try JSONSerialization.data(withJSONObject: state, options: [.withoutEscapingSlashes])
        for file in [stateFile, stateBackupFile] {
            let mode = (try? fm.attributesOfItem(atPath: file.path)[.posixPermissions]) ?? 0o644
            try data.write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
        let projects = (state["local-projects"] as? [String: Any])?.count ?? 0

        log("Your sidebar (\(projects) projects) is now kept for any sign-in.")
    }

    // Merges two versions of one sidebar value without dropping anything.
    // Dictionaries keep every entry, and newer wins when both have the same key.
    // Lists keep every item, with the older order first and new items appended.
    // A missing or null newer value never replaces an existing older one.
    private func combine(_ older: Any?, _ newer: Any?) -> Any? {
        switch (older, newer) {
        case (nil, _):
            return newer
        case let (old as [String: Any], new as [String: Any]):
            return old.merging(new) { _, new in new }
        case let (old as [Any], new as [Any]):
            var items = old
            for item in new where !items.contains(where: { ($0 as AnyObject).isEqual(item) }) { items.append(item) }
            return items
        case (_, nil), (_, is NSNull):
            return older
        default:
            return newer
        }
    }

    private func size(_ copy: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: copy).count) ?? 0
    }

    // Backups:

    private func backupState(log: (String) -> Void) throws {
        let formatter = DateFormatter()
        // A fixed locale keeps folder names sortable regardless of the 12/24-hour clock setting.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dest = backupRoot.appendingPathComponent(formatter.string(from: Date()))

        try fm.createDirectory(at: dest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for file in [stateFile, stateBackupFile] where fm.fileExists(atPath: file.path) {
            let copy = dest.appendingPathComponent(file.lastPathComponent)
            try? fm.removeItem(at: copy)
            try fm.copyItem(at: file, to: copy)
        }

        let backups = (try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)) ?? []
        for old in backups.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(Self.backupsToKeep) {
            try? fm.removeItem(at: old)
        }

        log("Backed up Codex's sidebar to \(dest.path).")
    }
}
