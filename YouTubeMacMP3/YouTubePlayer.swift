import SwiftUI
import WebKit

struct YouTubePlayer: NSViewRepresentable {
    let videoID: String

    func makeNSView(context: Context) -> WKWebView {
        let settings = WKWebViewConfiguration()
        settings.mediaTypesRequiringUserActionForPlayback = [.audio, .video]
        let view = WKWebView(frame: .zero, configuration: settings)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedVideoID != videoID else { return }
        context.coordinator.loadedVideoID = videoID
        guard videoID.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil,
              let url = URL(string: "https://www.youtube.com/embed/\(videoID)?playsinline=1&controls=1") else { return }
        var request = URLRequest(url: url)
        let appID = (Bundle.main.bundleIdentifier ?? "com.example.YouTubeMacMP3").lowercased()
        request.setValue("https://\(appID)", forHTTPHeaderField: "Referer")
        view.load(request)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedVideoID: String?
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[Playback] \(error.localizedDescription)")
        }
    }
}
