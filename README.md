# TranslatorApp

An iOS translator that offers a clean, focused interface for translating between English and Simplified Chinese using OpenAI's voice and chat models. Users can type or speak content, and the app displays both the detected source text and the translated output.

## Features

- SwiftUI interface with a segmented control to switch between English→Chinese and Chinese→English modes.
- Voice capture with live OpenAI transcription before translation.
- Manual text input workflow for quick translations without recording.
- Clear display of original and translated phrases along with progress and error states.

## Project structure

```
TranslatorApp/
├── TranslatorApp.xcodeproj    # Xcode project
└── TranslatorApp              # App sources, assets, and supporting files
```

Key source files:

- `TranslatorAppApp.swift` – Application entry point and dependency injection.
- `ContentView.swift` – SwiftUI layout, input controls, and status messaging.
- `ViewModel/TranslationViewModel.swift` – Business logic for translating and driving UI state.
- `Services/OpenAIService.swift` – Networking layer for transcription and chat completion requests.
- `Utilities/AudioRecorder.swift` – Handles AVFoundation recording and permission flow.

## Requirements

- Xcode 15 or later
- iOS 16 deployment target
- An OpenAI API key with access to Chat Completions and transcription models

## Setup

1. Open the project in Xcode: `TranslatorApp/TranslatorApp.xcodeproj`.
2. Add your API key to the run scheme environment variables or your shell environment as `OPENAI_API_KEY`.
3. Select a signing team under *Targets ▸ TranslatorApp ▸ Signing & Capabilities*.
4. Build and run on a simulator or physical device (`Cmd+R`).
   - Microphone capture only works on a real device; the simulator will not supply audio input.

## Privacy usage descriptions

`Info.plist` includes a microphone usage description. When running on device, iOS will prompt the user for permission the first time a recording is attempted.

## Notes

- The networking layer expects the `gpt-4o-mini` and `gpt-4o-mini-transcribe` models. Update the model identifiers if your OpenAI account provides different names.
- Error messages from the API are surfaced to the UI so users can retry when rate limits or network issues occur.
- The recorder writes temporary `.m4a` files that are deleted automatically once processing finishes.
