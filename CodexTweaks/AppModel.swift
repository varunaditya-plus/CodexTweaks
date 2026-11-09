import AppKit
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var authMode: String?
    @Published private(set) var codexInstalled = true
    @Published private(set) var busy: String?
    @Published private(set) var hasStoredKey = KeyStore.load() != nil

    let engine = TweakEngine()
    private var timer: Timer?
    private var checkedStateDate: Date?
    private var offeredRestart = false
    private var warned: Set<String> = []

    init() {
        refresh()
        // Sign-in can change from inside Codex, so poll the small auth file every 5 seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Codex quitting is the safe moment to edit its state file.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == TweakEngine.codexBundleID else { return }
            Task { @MainActor in self?.codexDidQuit() }
        }
    }

    var usingAPIKey: Bool { authMode == "apikey" }

    func refresh() {
        let mode = engine.authMode()
        if mode != authMode { authMode = mode }
        let installed = engine.codexInstalled
        if installed != codexInstalled { codexInstalled = installed }
        checkSidebar()
    }

    // Actions:

    func applyAPIKey() {
        guard let key = KeyStore.load() else { return }
        guard confirm("Use your API key in Codex?", "Codex will quit, sign in with your OpenAI API key and reopen. Your projects and chats will be kept. Usage is billed to the OpenAI Platform.")
        else { return }

        busy = "Checking key…"
        Task {
            if case .failure(let error) = await Self.testKey(key) {
                busy = nil
                alert("Your API key didn't work", error.localizedDescription, style: .warning)
                return
            }
            busy = nil
            perform("Applying API key…") { engine, log in try await engine.applyAPIKey(key, log: log) }
        }
    }

    func switchToOpenAIAccount() {
        guard confirm("Switch Codex to your OpenAI account?", "Codex will quit, sign out of your API key and reopen on its sign-in screen for you to log into. Your projects and chats will be kept.")
        else { return }
        perform("Switching…") { engine, log in try await engine.switchToOpenAIAccount(log: log) }
    }

    func openBackups() {
        try? FileManager.default.createDirectory(at: engine.backupRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(engine.backupRoot)
    }

    // API key:

    func saveKey(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-") else { throw TweakError("OpenAI API keys start with sk-.") }
        try KeyStore.save(key)
        hasStoredKey = true
    }

    func removeKey() {
        KeyStore.delete()
        hasStoredKey = false
    }

    // Codex's own login accepts any string, so the key is checked against the API first.
    nonisolated static func testKey(_ key: String) async -> Result<Void, TweakError> {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200: return .success(())
            case 401: return .failure(TweakError("OpenAI rejected this key."))
            case let code: return .failure(TweakError("OpenAI returned HTTP \(code ?? 0)."))
            }
        } catch {
            return .failure(TweakError(error.localizedDescription))
        }
    }

    // Launch at login:

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                try newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            } catch {
                alert("Couldn't change Launch at Login", error.localizedDescription, style: .warning)
            }
            // SMAppService isn't observable, so redraw the toggle manually.
            objectWillChange.send()
        }
    }

    // Background sidebar fixes:

    private func codexDidQuit() {
        offeredRestart = false
        guard busy == nil else { return }
        let engine = engine
        Task.detached {
            let failure = Self.combineInBackground(engine)
            await MainActor.run {
                if let failure { self.warnOnce(failure) }
                self.refresh()
            }
        }
    }

    nonisolated private static func combineInBackground(_ engine: TweakEngine) -> String? {
        if engine.hasUnknownAccountFormat() { return TweakEngine.unknownFormatMessage }
        do { try engine.combineIfSplit { _ in } } catch { return error.localizedDescription }
        return nil
    }

    // Background checks run every 5 seconds, so each problem is only shown once.
    private func warnOnce(_ message: String) {
        guard !warned.contains(message) else { return }
        warned.insert(message)
        alert("Codex Tweaks couldn't combine your sidebar", message, style: .warning)
    }

    // An in-app sign-out or account switch splits the sidebar while Codex is open.
    // The file can only be fixed while Codex is closed, so offer a restart once.
    // If you choose Later, it's combined when Codex quits.
    private func checkSidebar() {
        // Re-read the large state file only when it has changed, and stop after a restart was offered.
        guard busy == nil, !offeredRestart,
              let date = engine.stateModificationDate(), date != checkedStateDate else { return }
        checkedStateDate = date
        let engine = engine
        Task.detached {
            if engine.hasUnknownAccountFormat() {
                await MainActor.run { self.warnOnce(TweakEngine.unknownFormatMessage) }
                return
            }
            guard engine.sidebarIsSplit() else { return }
            guard engine.codexAppRunning() else {
                let failure = Self.combineInBackground(engine)
                if let failure { await MainActor.run { self.warnOnce(failure) } }
                return
            }
            await MainActor.run { self.offerRestart() }
        }
    }

    private func offerRestart() {
        guard busy == nil, !offeredRestart else { return }
        offeredRestart = true
        guard confirm("Combine your Codex sidebar?", "Signing in or out inside Codex gave this account a separate sidebar, so some projects are hidden. Restart Codex to bring everything back together, or it'll happen the next time Codex quits.", action: "Restart Codex", cancel: "Later")
        else { return }
        perform("Combining sidebar…") { engine, log in try await engine.combineSidebarAndRestart(log: log) }
    }

    // Running actions and alerts:

    private func perform(_ label: String, _ action: @escaping @Sendable (TweakEngine, (String) -> Void) async throws -> Void) {
        guard busy == nil else { return }
        busy = label
        let engine = engine
        Task.detached {
            var lines: [String] = []
            var failure: String?
            do { try await action(engine) { lines.append($0) } } catch { failure = error.localizedDescription }
            let errorText = failure
            
            // Progress-only lines are left out of the result alert.
            let summary = lines.filter { !$0.hasPrefix("Backed up") && !$0.hasPrefix("Quitting") }
            await MainActor.run {
                self.busy = nil
                self.refresh()
                if let errorText {
                    self.alert("Something went wrong", errorText, style: .warning)
                } else if !summary.isEmpty {
                    self.alert("Done", summary.joined(separator: "\n"))
                }
            }
        }
    }

    private func confirm(_ title: String, _ text: String, action: String = "Continue", cancel: String = "Cancel") -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func alert(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
