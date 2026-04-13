import SwiftUI

@main
struct DiskMapperApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
    }
}
