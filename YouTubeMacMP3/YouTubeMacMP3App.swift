import SwiftUI

@main
struct YouTubeMacMP3App: App {
    var body: some Scene {
        WindowGroup("YouTube 검색 · MP3") {
            ContentView()
                .frame(minWidth: 940, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 760)
    }
}
