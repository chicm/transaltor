import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: TranslationViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                conversationSection

                if !viewModel.debugMessages.isEmpty {
                    debugConsole
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()

                voiceButton
            }
            .padding(24)
            .navigationTitle("Voice Translator")
        }
    }

    private var conversationSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if viewModel.transcripts.isEmpty {
                    Text("Tap the button and start speaking. I'll capture the audio and display the transcript once recognition is wired up.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    ForEach(viewModel.transcripts) { utterance in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(utterance.text.isEmpty ? "(empty)" : utterance.text)
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var voiceButton: some View {
        VoiceControlButton(state: viewModel.state) {
            viewModel.toggleVoiceInteraction()
        }
    }

    private var debugConsole: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Debug Output")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    viewModel.clearDebugLogs()
                }
                .font(.caption)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(viewModel.debugMessages.enumerated()), id: \.offset) { entry in
                        Text(entry.element)
                            .font(.caption2.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct VoiceControlButton: View {
    let state: VoiceSessionState
    let action: () -> Void

    @State private var animatePulse = false
    private let pulseAnimation = Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)

    private var isActive: Bool {
        state != .idle
    }

    private var title: String {
        state == .idle ? "Start Listening" : "Listening..."
    }

    private var iconName: String {
        state == .idle ? "waveform.circle.fill" : "waveform"
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if isActive {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 6)
                        .frame(width: 220, height: 220)
                        .scaleEffect(animatePulse ? 1.2 : 0.9)
                        .opacity(animatePulse ? 0.2 : 0.5)
                        .animation(pulseAnimation, value: animatePulse)
                        .onAppear { startPulse() }
                        .onDisappear { stopPulse() }
                }

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.accentColor, .accentColor.opacity(0.4)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 140
                        )
                    )
                    .frame(width: 180, height: 180)
                    .shadow(color: .accentColor.opacity(0.4), radius: 20)

                VStack(spacing: 8) {
                    Image(systemName: iconName)
                        .font(.system(size: 44, weight: .semibold))
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private func startPulse() {
        animatePulse = false
        DispatchQueue.main.async {
            withAnimation(pulseAnimation) {
                animatePulse = true
            }
        }
    }

    private func stopPulse() {
        withAnimation(.easeOut(duration: 0.2)) {
            animatePulse = false
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(TranslationViewModel())
    }
}
#endif
