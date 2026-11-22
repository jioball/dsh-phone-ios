import SwiftUI
import WebKit

/// URL of the dsh-phone PWA served by the DSH host plugin.
let PHONE_URL = URL(string: "https://babel.tail977397.ts.net:8443/")!
let PHONE_HOST = "babel.tail977397.ts.net"

@main
struct DSHPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            WebView().ignoresSafeArea()
        }
    }
}

struct WebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.039, green: 0.039, blue: 0.047, alpha: 1)
        web.load(URLRequest(url: PHONE_URL))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// Trust the pinned host's self-signed certificate, and nothing else.
        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.host == PHONE_HOST,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        /// Reload if iOS kills the web content process (memory pressure).
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.load(URLRequest(url: PHONE_URL))
        }
    }
}
