import SwiftUI

@main
struct JustBashPhoneApp: App {
    init() {
        JustBashShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
