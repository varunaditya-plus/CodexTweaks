import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.busy ?? headline)

        Divider()

        if model.usingAPIKey {
            Button("Switch to OpenAI account") { model.switchToOpenAIAccount() }
                .disabled(model.busy != nil || !model.codexInstalled)
        } else {
            // Without a saved key, open Settings to add one first.
            Button("Apply API Key to Codex") { model.hasStoredKey ? model.applyAPIKey() : showSettings() }
                .disabled(model.busy != nil || !model.codexInstalled)
        }
        Button("Open Backups Folder") { model.openBackups() }

        Divider()

        Button("Settings") { showSettings() }
            .keyboardShortcut(",")
        Button("Quit Codex Tweaks") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var headline: String {
        guard model.codexInstalled else { return "Codex isn't installed" }
        switch model.authMode {
        case "apikey": return "Codex is using your API key"
        case nil: return "Codex is signed out"
        default: return "Codex is using your OpenAI account"
        }
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }
}
