import SwiftUI

@main struct GitScopeApp: App {
    var body: some Scene {
        WindowGroup { ContentView().frame(minWidth: 980, minHeight: 680) }
            .defaultSize(width: 1200, height: 820)
            .commands { CommandGroup(replacing: .newItem) { } }
    }
}
