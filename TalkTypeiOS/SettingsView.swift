import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var selectedModel: String = defaultOpenAIASRModel
    @State private var newWord: String = ""
    @State private var showingKeyAlert = false
    @State private var keyAlertMessage = ""
    @State private var isSavingKey = false
    @State private var vocabEntries: [VocabEntry] = []

    private let provider: ASRProvider = .openai

    var body: some View {
        NavigationStack {
            List {
                keyboardSetupSection
                apiKeySection
                modelSection
                vocabularySection
            }
            .navigationTitle("TalkType")
            .onAppear { loadState() }
            .alert("API Key", isPresented: $showingKeyAlert) {
                Button("OK") {}
            } message: {
                Text(keyAlertMessage)
            }
        }
    }

    // MARK: - Keyboard Setup

    private var keyboardSetupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("Setup Guide", systemImage: "keyboard")
                    .font(.headline)

                SetupStep(number: 1, text: "Open Settings > General > Keyboard > Keyboards")
                SetupStep(number: 2, text: "Tap \"Add New Keyboard...\"")
                SetupStep(number: 3, text: "Select \"TalkType\"")
                SetupStep(number: 4, text: "Tap TalkType > Enable \"Allow Full Access\"")
                SetupStep(number: 5, text: "Use the globe key to switch to TalkType")

                Button("Open Keyboard Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Keyboard")
        }
    }

    // MARK: - API Key

    private var apiKeySection: some View {
        Section {
            SecureField("OpenAI API Key", text: $apiKey)
                .textContentType(.password)
                .autocorrectionDisabled()

            Button {
                saveAPIKey()
            } label: {
                HStack {
                    Text("Save Key")
                    if isSavingKey {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(apiKey.isEmpty || isSavingKey)

            if KeyStorage.retrieveKey(provider: provider.keyAccount) != nil {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("API key saved")
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("Your key is stored securely in the iOS Keychain and shared with the keyboard extension.")
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            Picker("Model", selection: $selectedModel) {
                ForEach(provider.models, id: \.id) { model in
                    Text(model.label).tag(model.id)
                }
            }
            .onChange(of: selectedModel) { newValue in
                var config = ConfigManager.load()
                config.asrModel = newValue
                ConfigManager.save(config)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("gpt-4o-mini-transcribe is fast and affordable. gpt-4o-transcribe is higher quality.")
        }
    }

    // MARK: - Vocabulary

    private var vocabularySection: some View {
        Section {
            HStack {
                TextField("Add word or phrase", text: $newWord)
                    .autocorrectionDisabled()
                Button("Add") {
                    addWord()
                }
                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            ForEach(vocabEntries, id: \.id) { entry in
                Text(entry.canonical)
            }
            .onDelete { indexSet in
                deleteWords(at: indexSet)
            }
        } header: {
            Text("Vocabulary (\(vocabEntries.count))")
        } footer: {
            Text("Add proper names, technical terms, or words that are often transcribed incorrectly.")
        }
    }

    // MARK: - Actions

    private func loadState() {
        let config = ConfigManager.load()
        selectedModel = config.asrModel
        let store = VocabularyStore()
        vocabEntries = store.listEntries()
    }

    private func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSavingKey = true
        Task {
            do {
                try Transcriber.validateKey(trimmed, modelsEndpoint: provider.modelsEndpoint, provider: provider)
                if KeyStorage.storeKey(provider: provider.keyAccount, apiKey: trimmed) {
                    await MainActor.run {
                        apiKey = ""
                        keyAlertMessage = "API key saved successfully."
                        showingKeyAlert = true
                        isSavingKey = false
                    }
                }
            } catch {
                await MainActor.run {
                    keyAlertMessage = "Invalid API key: \(error.localizedDescription)"
                    showingKeyAlert = true
                    isSavingKey = false
                }
            }
        }
    }

    private func addWord() {
        let store = VocabularyStore()
        _ = try? store.add(newWord)
        newWord = ""
        vocabEntries = store.listEntries()
    }

    private func deleteWords(at offsets: IndexSet) {
        let store = VocabularyStore()
        for index in offsets {
            store.remove(entryID: vocabEntries[index].id)
        }
        vocabEntries = store.listEntries()
    }
}

// MARK: - Setup Step

private struct SetupStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))

            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}
