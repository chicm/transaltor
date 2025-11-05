import SwiftUI

@main
struct TranslatorAppApp: App {
    @StateObject private var viewModel = TranslationViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
    }
}
