import SwiftUI

@main
struct JustBashPhoneApp: App {
    init() {
        CodexBackgroundScheduler.register()
        JustBashShortcuts.updateAppShortcutParameters()
        Task {
            if (try? await CodexBackgroundQueue.shared.hasPendingJobs()) == true {
                CodexBackgroundScheduler.scheduleRefresh(after: 60)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
