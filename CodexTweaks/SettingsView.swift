import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @State private var savedKey: String?
    @State private var saving = false
    @State private var feedback: (text: String, ok: Bool)?

    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $draft, prompt: Text("sk-…"))
                    .onSubmit(save)
                HStack {
                    if let feedback {
                        Label(feedback.text, systemImage: feedback.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(feedback.ok ? .green : .orange)
                    } else if saving {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    if model.hasStoredKey {
                        Button("Remove") {
                            model.removeKey()
                            draft = ""
                            savedKey = nil
                            feedback = nil
                        }
                    }
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmedDraft.isEmpty || trimmedDraft == savedKey || saving)
                }
            } header: {
                Text("OpenAI API Key")
            } footer: {
                Text("Usage is billed to the OpenAI Platform account that owns the key.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        .onAppear {
            if let key = KeyStore.load() {
                draft = key
                savedKey = key
            }
        }
        .onChange(of: draft) { feedback = nil }
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        let key = trimmedDraft
        saving = true
        Task {
            defer { saving = false }
            if case .failure(let error) = await AppModel.testKey(key) {
                feedback = (error.localizedDescription, false)
                return
            }
            do {
                try model.saveKey(key)
                savedKey = key
                feedback = ("Saved", true)
                // Offer to use the new key in Codex right away; the confirmation lets you decline.
                if model.codexInstalled { model.applyAPIKey() }
            } catch {
                feedback = (error.localizedDescription, false)
            }
        }
    }
}
