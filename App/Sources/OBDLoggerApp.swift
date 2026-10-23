import SwiftUI

@main
struct OBDLoggerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 460, height: 620)
        #endif
    }
}
