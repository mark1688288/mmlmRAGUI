import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
/// Scene identifiers. `main` is the tabbed conversation. `compare` is the one side-by-side window.
enum RagWindowID {
    static let main = "mmlm"
    static let compare = "mmlm-compare"
}

/// Quit closes every window with `close()`. That path must not stop to ask,
/// or termination waits on a tab that never goes away.
final class RagAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        QuestionCloseTermination.begin()
        return .terminateNow
    }
}
#endif

@main struct MyApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(RagAppDelegate.self) private var appDelegate
    @State private var settings = RagSettings()
    @State private var history = QuestionHistoryStore()
    @State private var interfaceLanguage = InterfaceLanguage.shared
    #endif

    var body: some Scene {
        #if os(macOS)
        WindowGroup(id: RagWindowID.main) {
            ContentView(settings: settings, history: history)
                .environment(\.locale, interfaceLanguage.language.locale)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            SidebarCommands()
        }

        Window(interfaceLanguage.text("Compare Tabs"), id: RagWindowID.compare) {
            TabComparePage()
                .environment(\.locale, interfaceLanguage.language.locale)
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            SettingsTabs(settings: settings)
                .environment(\.locale, interfaceLanguage.language.locale)
        }
        .defaultSize(width: 440, height: 560)
        #else
        WindowGroup {
            ContentView()
        }
        #endif
    }
}
