import SwiftUI

@main
struct CantusApp: App {
    @State private var library = LibraryModel()
    @State private var engine = PlayerEngine()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(engine)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
