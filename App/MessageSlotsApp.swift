import SwiftUI

@main
struct MessageSlotsApp: App {
    var body: some Scene {
        WindowGroup {
            GameScreen()
                .preferredColorScheme(.dark)
        }
    }
}
