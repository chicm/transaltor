import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: TranslationViewModel
    @FocusState private var isSourceFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Picker("Mode", selection: $viewModel.mode) {
                    ForEach(TranslationMode.allCases) { mode in
                        Text(mode.title)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Source")
                        .font(.headline)
                    TextEditor(text: $viewModel.sourceText)
                        .focused($isSourceFocused)
                        .frame(minHeight: 120)
                        .padding(12)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Translation")
                            .font(.headline)
                        Spacer()
                        if viewModel.isProcessing {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if viewModel.translatedText.isEmpty {
                                Text("The translation will appear here.")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(viewModel.translatedText)
                                    .font(.title3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .frame(minHeight: 120)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }

                HStack(spacing: 16) {
                    Button(action: {
                        Task { await viewModel.translateCurrentText() }
                    }) {
                        Label("Translate", systemImage: "arrow.right.circle.fill")
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.sourceText.isEmpty || viewModel.isProcessing)

                    Button(action: {
                        Task { await viewModel.toggleRecording() }
                    }) {
                        Label(viewModel.isRecording ? "Stop" : "Speak", systemImage: viewModel.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.headline)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(viewModel.isRecording ? .red : .accentColor)
                    .disabled(viewModel.isProcessing)
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Translator")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isSourceFocused = false }
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(TranslationViewModel())
}
