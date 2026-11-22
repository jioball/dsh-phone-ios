import SwiftUI
import WebKit
import PhotosUI
import UniformTypeIdentifiers

/// URL of the dsh-phone PWA served by the DSH host plugin.
let PHONE_URL = URL(string: "https://babel.tail977397.ts.net:8443/")!
let PHONE_HOST = "babel.tail977397.ts.net"

/// Max bytes of a document we're willing to base64 across the JS bridge.
let MAX_DOC_BYTES = 8 * 1024 * 1024
let MAX_IMAGE_SIDE: CGFloat = 1600
let JPEG_QUALITY: CGFloat = 0.85

func mimeFor(extension ext: String) -> String {
    switch ext.lowercased() {
    case "txt": return "text/plain"
    case "md", "markdown": return "text/markdown"
    case "json": return "application/json"
    case "csv": return "text/csv"
    case "pdf": return "application/pdf"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "webp": return "image/webp"
    case "gif": return "image/gif"
    case "html", "htm": return "text/html"
    case "xml": return "text/xml"
    default: return "application/octet-stream"
    }
}

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
        config.userContentController.add(context.coordinator, name: "phone")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.039, green: 0.039, blue: 0.047, alpha: 1)
        context.coordinator.web = web
        web.load(URLRequest(url: PHONE_URL))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler,
                             PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
        weak var web: WKWebView?

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

        /// JS: window.webkit.messageHandlers.phone.postMessage({ kind: "photos" | "documents" })
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "phone",
                  let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String,
                  let top = Self.topViewController() else { return }
            switch kind {
            case "photos":
                var config = PHPickerConfiguration()
                config.selectionLimit = 10
                config.filter = .images
                let picker = PHPickerViewController(configuration: config)
                picker.delegate = self
                top.present(picker, animated: true)
            case "documents":
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
                picker.allowsMultipleSelection = true
                picker.delegate = self
                top.present(picker, animated: true)
            default:
                break
            }
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            let queue = DispatchQueue(label: "phone.photos")
            var files: [[String: Any]] = []
            let group = DispatchGroup()
            for result in results {
                let provider = result.itemProvider
                guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { continue }
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                    defer { group.leave() }
                    guard error == nil, let url = url, let data = try? Data(contentsOf: url),
                          let image = UIImage(data: data) else { return }
                    let scale = min(1, MAX_IMAGE_SIDE / max(image.size.width, image.size.height))
                    let size = CGSize(width: max(1, image.size.width * scale),
                                      height: max(1, image.size.height * scale))
                    let renderer = UIGraphicsImageRenderer(size: size)
                    let jpeg = renderer.jpegData(withCompressionQuality: JPEG_QUALITY) { _ in
                        image.draw(in: CGRect(origin: .zero, size: size))
                    }
                    let entry: [String: Any] = [
                        "name": url.lastPathComponent,
                        "mediaType": "image/jpeg",
                        "data": jpeg.base64EncodedString(),
                    ]
                    queue.sync { files.append(entry) }
                }
            }
            group.notify(queue: .main) { [weak self] in
                self?.postFiles(files, kind: "photos")
            }
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            var files: [[String: Any]] = []
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                guard data.count <= MAX_DOC_BYTES else {
                    postNotice("\(url.lastPathComponent) is too large to send from the phone")
                    continue
                }
                files.append([
                    "name": url.lastPathComponent,
                    "mediaType": mimeFor(extension: url.pathExtension),
                    "data": data.base64EncodedString(),
                ])
            }
            postFiles(files, kind: "documents")
        }

        func postNotice(_ text: String) {
            postJS("window.__phoneNotice && window.__phoneNotice(\(Self.jsString(text)))")
        }

        func postFiles(_ files: [[String: Any]], kind: String) {
            guard !files.isEmpty else { return }
            guard let data = try? JSONSerialization.data(withJSONObject: ["kind": kind, "files": files]),
                  let json = String(data: data, encoding: .utf8) else { return }
            postJS("window.__phoneFiles && window.__phoneFiles(\(json))")
        }

        func postJS(_ call: String) {
            guard let web = web else { return }
            DispatchQueue.main.async {
                web.evaluateJavaScript(call, completionHandler: nil)
            }
        }

        static func jsString(_ text: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: [text])
            let arr = String(data: data, encoding: .utf8)!
            return String(arr.dropFirst().dropLast())
        }

        static func topViewController() -> UIViewController? {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
                let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
            else { return nil }
            var top = root
            while let presented = top.presentedViewController { top = presented }
            return top
        }
    }
}
