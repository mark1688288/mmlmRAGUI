import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1080, height: 720)
        #else
        WindowGroup {
            ContentView()
        }
        #endif
    }
}
