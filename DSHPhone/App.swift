import SwiftUI
import WebKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import MediaPlayer

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
        /* Re-seed the pairing PIN into localStorage before any page script runs,
           so the pairing screen only appears when the PIN genuinely changes. */
        if let token = UserDefaults.standard.string(forKey: "phoneToken"), !token.isEmpty {
            let script = WKUserScript(
                source: "localStorage.setItem('dsh-phone-token', \(Coordinator.jsString(token)));",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(script)
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.alwaysBounceVertical = false  /* the chat list scrolls; never the shell */
        web.scrollView.keyboardDismissMode = .onDrag /* scroll gesture dismisses keyboard, doesn't drag it */
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.039, green: 0.039, blue: 0.047, alpha: 1)
        context.coordinator.web = web
        context.coordinator.stripKeyboardAccessoryBar(from: web)
        web.load(URLRequest(url: PHONE_URL))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler,
                             PHPickerViewControllerDelegate, UIDocumentPickerDelegate,
                             AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
        weak var web: WKWebView?
        let synthesizer = AVSpeechSynthesizer()
        var audioPlayer: AVAudioPlayer?
        var nowPlayingTimer: Timer?
        var keyboardAccessoryObserver: NSObjectProtocol?

        override init() {
            super.init()
            synthesizer.delegate = self
            setupRemoteCommands()
        }

        /* ---------- keyboard accessory bar ---------- */

        /// WKWebView adds its own form toolbar (◀ ▶ Done) above the keyboard.
        /// DeepSeek's composer has no such bar, so hide it whenever it appears.
        func stripKeyboardAccessoryBar(from web: WKWebView) {
            keyboardAccessoryObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.hideAccessoryViews()
            }
        }

        func hideAccessoryViews() {
            for scene in UIApplication.shared.connectedScenes {
                guard let ws = scene as? UIWindowScene else { continue }
                for window in ws.windows { hideAccessoryViews(in: window) }
            }
        }

        func hideAccessoryViews(in view: UIView) {
            let name = String(describing: type(of: view))
            if name.contains("InputAccessory") || name.contains("AccessoryView"),
               view.frame.height > 0, view.frame.height < 90 {
                view.isHidden = true
                return
            }
            for sub in view.subviews { hideAccessoryViews(in: sub) }
        }

        deinit {
            if let observer = keyboardAccessoryObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        /// Playback session. duck=true → .duckOthers (other audio dips, but iOS
        /// will NOT give us the Now Playing card). duck=false → plain .playback
        /// (card + controls are ours; other apps' audio pauses instead).
        func activateAudioSession(duck: Bool) {
            let options: AVAudioSession.CategoryOptions = duck ? [.duckOthers] : []
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: options)
            try? AVAudioSession.sharedInstance().setActive(true)
        }

        func deactivateAudioSession() {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        func setupRemoteCommands() {
            let center = MPRemoteCommandCenter.shared()
            center.playCommand.isEnabled = true
            center.playCommand.addTarget { [weak self] _ in
                self?.audioPlayer?.play()
                self?.postNotice("⏯ lock-screen: play")
                self?.postJS("window.__phoneTtsState && window.__phoneTtsState('start')")
                return .success
            }
            center.pauseCommand.isEnabled = true
            center.pauseCommand.addTarget { [weak self] _ in
                self?.audioPlayer?.pause()
                self?.postNotice("⏯ lock-screen: pause")
                self?.postJS("window.__phoneTtsState && window.__phoneTtsState('pause')")
                return .success
            }
            center.togglePlayPauseCommand.isEnabled = true
            center.togglePlayPauseCommand.addTarget { [weak self] _ in
                guard let player = self?.audioPlayer else { return .commandFailed }
                if player.isPlaying {
                    player.pause()
                    self?.postJS("window.__phoneTtsState && window.__phoneTtsState('pause')")
                } else {
                    player.play()
                    self?.postJS("window.__phoneTtsState && window.__phoneTtsState('start')")
                }
                return .success
            }
            center.changePlaybackPositionCommand.isEnabled = true
            center.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                self?.audioPlayer?.currentTime = event.positionTime
                self?.refreshNowPlayingElapsed()
                return .success
            }
            center.nextTrackCommand.isEnabled = true
            center.nextTrackCommand.addTarget { [weak self] _ in
                self?.postJS("window.__phoneCommand && window.__phoneCommand('next')")
                return .success
            }
            center.previousTrackCommand.isEnabled = true
            center.previousTrackCommand.addTarget { [weak self] _ in
                self?.postJS("window.__phoneCommand && window.__phoneCommand('prev')")
                return .success
            }
        }

        func updateNowPlaying(title: String, duration: TimeInterval) {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: title,
                MPMediaItemPropertyArtist: "dsh-phone",
                MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            ]
            if duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }

        func refreshNowPlayingElapsed() {
            guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audioPlayer?.currentTime ?? 0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }

        func startNowPlayingTimer() {
            nowPlayingTimer?.invalidate()
            nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.refreshNowPlayingElapsed()
            }
        }

        func stopNowPlayingTimer() {
            nowPlayingTimer?.invalidate()
            nowPlayingTimer = nil
        }

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

        /// Advertise native playback capability once the page is up.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("window.__phoneHasPlayAudio = true;", completionHandler: nil)
        }

        /// JS: window.webkit.messageHandlers.phone.postMessage({ kind: "photos" | "documents" })
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "phone",
                  let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String,
                  let top = Self.topViewController() else { return }
            switch kind {
            case "setToken":
                if let token = body["token"] as? String, !token.isEmpty {
                    UserDefaults.standard.set(token, forKey: "phoneToken")
                }
            case "clearToken":
                UserDefaults.standard.removeObject(forKey: "phoneToken")
            case "listVoices":
                let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
                let arr = voices.map { ["name": $0.name, "id": $0.identifier, "lang": $0.language] }
                if let data = try? JSONSerialization.data(withJSONObject: arr),
                   let json = String(data: data, encoding: .utf8) {
                    postJS("window.__phoneVoices && window.__phoneVoices(\(json))")
                }
            case "speak":
                let utterance = AVSpeechUtterance(string: body["text"] as? String ?? "")
                if let identifier = body["voiceId"] as? String,
                   let v = AVSpeechSynthesisVoice(identifier: identifier) {
                    utterance.voice = v
                }
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate * (body["rate"] as? Float ?? 1.05)
                utterance.pitchMultiplier = body["pitch"] as? Float ?? 1.0
                activateAudioSession(duck: true)
                synthesizer.speak(utterance)
            case "stopSpeech":
                synthesizer.stopSpeaking(at: .immediate)
                deactivateAudioSession()
            case "playAudio":
                if let b64 = body["data"] as? String, let data = Data(base64Encoded: b64) {
                    let duck = body["duck"] as? Bool ?? false
                    activateAudioSession(duck: duck)
                    audioPlayer = try? AVAudioPlayer(data: data)
                    audioPlayer?.delegate = self
                    audioPlayer?.play()
                    let title = (body["title"] as? String)?.isEmpty == false
                        ? (body["title"] as! String)
                        : "Assistant message"
                    let duration = audioPlayer?.duration ?? 0
                    updateNowPlaying(title: title, duration: duration)
                    refreshNowPlayingElapsed()
                    startNowPlayingTimer()
                    postNotice("🎧 Now Playing: \(title.prefix(60)) · \(String(format: "%.1f", duration))s · duck=\(duck)")
                    /* re-assert metadata shortly after playback settles — something
                       (often the webview) can clear it right at session activation */
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        guard let self, self.audioPlayer?.isPlaying == true else { return }
                        self.updateNowPlaying(title: title, duration: duration)
                        self.refreshNowPlayingElapsed()
                    }
                    postJS("window.__phoneTtsState && window.__phoneTtsState('start')")
                }
            case "stopAudio":
                audioPlayer?.stop()
                stopNowPlayingTimer()
                refreshNowPlayingElapsed()
                deactivateAudioSession()
                postJS("window.__phoneTtsState && window.__phoneTtsState('end')")
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

        /* AVSpeechSynthesizer callbacks → tell the page when playback starts/ends */
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
            postJS("window.__phoneTtsState && window.__phoneTtsState('start')")
        }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            postJS("window.__phoneTtsState && window.__phoneTtsState('end')")
        }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            postJS("window.__phoneTtsState && window.__phoneTtsState('end')")
        }

        /* AVAudioPlayer (neural mp3 playback) callbacks */
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            stopNowPlayingTimer()
            refreshNowPlayingElapsed()
            deactivateAudioSession()
            postJS("window.__phoneTtsState && window.__phoneTtsState('end')")
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
