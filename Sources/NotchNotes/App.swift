import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--selfcheck") {
            SelfCheck.run()
            exit(0)
        }
        NotchNotesApp.main()
    }
}

struct NotchNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Обычных окон нет — всё живёт в панели у челки
        Settings { EmptyView() }
    }
}
