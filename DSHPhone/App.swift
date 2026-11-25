import SwiftUI
import WebKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import MediaPlayer
import ObjectiveC

/// WKWebView subclass that refuses a keyboard input accessory: WebKit then
/// neither draws its ◀ ▶ Done bar nor reserves the ~44pt it occupies.
final class NoAccessoryWebView: WKWebView {
    override var inputAccessoryView: UIView? { nil }
}

/// Swizzle helper: makes the internal WKContentView's inputAccessoryView nil.
private final class AccessoryNilHelper: NSObject {
    @objc var inputAccessoryView: UIView? { nil }
}

func suppressKeyboardAccessory(in web: WKWebView) {
    guard let content = web.scrollView.subviews.first(where: {
        String(describing: type(of: $0)).hasPrefix("WKContent")
    }) else { return }
    let cls: AnyClass = type(of: content)
    guard let original = class_getInstanceMethod(cls, Selector(("inputAccessoryView"))),
          let swizzled = class_getInstanceMethod(AccessoryNilHelper.self, Selector(("inputAccessoryView")))
    else { return }
    method_exchangeImplementations(original, swizzled)
}

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
    init() {
        /* the shake gesture pops iOS's Cancel/Undo menu over the webview - off */
        UIApplication.shared.applicationSupportsShakeToEdit = false
    }
    /* every layer behind the page must be the page's own colour: WKWebView is
       non-opaque here, so an unset container shows iOS systemBackground (grey)
       in any strip the page does not paint - the "black bar that turns grey". */
    static let pageColor = Color(red: 17.0 / 255.0, green: 17.0 / 255.0, blue: 17.0 / 255.0)

    var body: some Scene {
        WindowGroup {
            ZStack {
                DSHPhoneApp.pageColor.ignoresSafeArea()
                /* .keyboard: SwiftUI must NOT shrink the webview for the keyboard —
                   its avoidance subtracts the accessory-bar allowance and leaves a
                   dead band. The page positions its composer from visualViewport. */
                WebView().ignoresSafeArea().ignoresSafeArea(.keyboard, edges: .bottom)
            }
            .background(DSHPhoneApp.pageColor.ignoresSafeArea())
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
        let web = NoAccessoryWebView(frame: .zero, configuration: config)
        if #available(iOS 16.4, *) {
            /* lets ios_webkit_debug_proxy / Inspect.app attach to the live app */
            web.isInspectable = true
        }
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.alwaysBounceVertical = false  /* the chat list scrolls; never the shell */
        web.scrollView.keyboardDismissMode = .onDrag /* scroll gesture dismisses keyboard, doesn't drag it */
        web.isOpaque = false
        /* match the page (#111111) on every background layer WKWebView owns */
        let pageBG = UIColor(red: 17.0 / 255.0, green: 17.0 / 255.0, blue: 17.0 / 255.0, alpha: 1.0)
        web.backgroundColor = pageBG
        web.scrollView.backgroundColor = pageBG
        web.underPageBackgroundColor = pageBG
        context.coordinator.web = web
        context.coordinator.stripKeyboardAccessoryBar(from: web)
        suppressKeyboardAccessory(in: web)
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
        var audioRecorder: AVAudioRecorder?
        var recordingURL: URL?
        var recordingCancelled = false
        var nowPlayingTimer: Timer?
        var keyboardAccessoryObserver: NSObjectProtocol?

        /* ---------- native voice channel (locked-phone read-aloud) ---------- */
        var liveChannelEnabled = false
        var liveChannelURL: URL?
        var liveChannelTask: URLSessionWebSocketTask?
        var liveChannelAttempts = 0
        var lastVoiceId: String?
        var lastVisible = true
        var keepAliveOn = false
        var keepAlivePlayer: AVAudioPlayer?
        var keepAliveURL: URL?
        var isBackground = false

        override init() {
            super.init()
            synthesizer.delegate = self
            setupRemoteCommands()
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.isBackground = true
                self?.startKeepAliveIfNeeded()
            }
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.isBackground = false
                self?.stopKeepAlive()
            }
        }

        /* ---------- keyboard accessory bar ---------- */

        /// WKWebView adds its own form toolbar (◀ ▶ Done) above the keyboard and
        /// reserves its height even when hidden. DeepSeek's composer has no such
        /// bar: hide the accessory view AND zero the scroll insets it leaves behind.
        func stripKeyboardAccessoryBar(from web: WKWebView) {
            keyboardAccessoryObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.hideAccessoryViews()
            }
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.hideAccessoryViews()
                self?.zeroKeyboardInsets()
                self?.forceFullHeight()
            }
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.web?.scrollView.contentInset = .zero
                self?.web?.scrollView.verticalScrollIndicatorInsets = .zero
            }
        }

        /// WebKit shrinks the webview by keyboard + accessory allowance; restore
        /// the full height after the keyboard settles so the page's own
        /// visualViewport math controls the composer position exactly.
        func forceFullHeight() {
            guard let web = web, let window = web.window else { return }
            let target = window.bounds
            for delay in [0.0, 0.15, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let web = self?.web, let w = web.window else { return }
                    if web.frame.size != w.bounds.size {
                        web.frame = w.bounds
                        web.layoutIfNeeded()
                    }
                }
            }
        }

        /// Any residual bottom contentInset the keyboard machinery left on the
        /// scroll view would show up as a dead band between the page and the keys.
        func zeroKeyboardInsets() {
            guard let web = web else { return }
            web.scrollView.contentInset = .zero
            web.scrollView.verticalScrollIndicatorInsets = .zero
            web.scrollView.horizontalScrollIndicatorInsets = .zero
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
            /* report the installed IPA so the phone can announce a newer build */
            let info = Bundle.main.infoDictionary ?? [:]
            let version = info["CFBundleShortVersionString"] as? String ?? "0"
            let build = info["CFBundleVersion"] as? String ?? "0"
            let js = "window.__phoneAppVersion && window.__phoneAppVersion('\(version)', '\(build)');"
            webView.evaluateJavaScript(js, completionHandler: nil)
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
            case "startRec":
                /* native voice recording: inherits the process's mic grant, so
                   no per-session prompt (webview getUserMedia prompts every run) */
                startNativeRecording()
            case "stopRec":
                stopNativeRecording()
            case "cancelRec":
                cancelNativeRecording()
            case "liveChannel":
                /* the page hands us the host channel URL; we keep our own socket
                   so reply audio still arrives while the webview is frozen */
                let enabled = body["enabled"] as? Bool ?? false
                liveChannelEnabled = enabled
                if let urlString = body["url"] as? String, let url = URL(string: urlString) {
                    liveChannelURL = url
                }
                liveChannelAttempts = 0
                if enabled {
                    openLiveChannel()
                } else {
                    liveChannelTask?.cancel(with: .goingAway, reason: nil)
                    liveChannelTask = nil
                }
            case "visibility":
                lastVisible = body["visible"] as? Bool ?? true
            case "keepAlive":
                keepAliveOn = body["on"] as? Bool ?? false
                if keepAliveOn {
                    startKeepAliveIfNeeded()
                } else {
                    stopKeepAlive()
                }
            case "openURL":
                if let s = body["url"] as? String, let url = URL(string: s) {
                    UIApplication.shared.open(url)
                }
            case "savePhoto":
                if let b64 = body["data"] as? String, let data = Data(base64Encoded: b64), let image = UIImage(data: data) {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    postNotice("Saved to Photos")
                }
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
            /* keep the process awake between replies while locked */
            if keepAliveOn && isBackground { startKeepAliveIfNeeded() }
        }

        /* ---------- native voice recording (16 kHz mono PCM16 WAV) ---------- */
        func startNativeRecording() {
            let session = AVAudioSession.sharedInstance()
            session.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !granted {
                        self.postJS("window.__phoneRecError && window.__phoneRecError('denied')")
                        return
                    }
                    do {
                        try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .mixWithOthers])
                        try session.setActive(true)
                    } catch {}
                    let dir = FileManager.default.temporaryDirectory
                    let url = dir.appendingPathComponent("rec-\(UUID().uuidString).wav")
                    let settings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatLinearPCM),
                        AVSampleRateKey: 16000,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsFloatKey: false,
                    ]
                    self.recordingCancelled = false
                    self.recordingURL = url
                    self.audioRecorder = try? AVAudioRecorder(url: url, settings: settings)
                    self.audioRecorder?.record()
                    self.postJS("window.__phoneRecState && window.__phoneRecState('start')")
                }
            }
        }

        func stopNativeRecording() {
            guard let recorder = audioRecorder else { return }
            recorder.stop()
            audioRecorder = nil
            let url = recordingURL
            recordingURL = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                if self.recordingCancelled { self.recordingCancelled = false; return }
                if let url, let data = try? Data(contentsOf: url) {
                    let b64 = data.base64EncodedString()
                    self.postJS("window.__phoneAudio && window.__phoneAudio('\(b64)')")
                } else {
                    self.postJS("window.__phoneRecError && window.__phoneRecError('empty')")
                }
            }
        }

        func cancelNativeRecording() {
            recordingCancelled = true
            audioRecorder?.stop()
            audioRecorder = nil
            recordingURL = nil
            postJS("window.__phoneRecState && window.__phoneRecState('end')")
        }

        /* ---------- native voice channel: locked-phone read-aloud ---------- */

        func openLiveChannel() {
            guard liveChannelEnabled, let url = liveChannelURL else { return }
            liveChannelTask?.cancel(with: .goingAway, reason: nil)
            let task = URLSession.shared.webSocketTask(with: url)
            liveChannelTask = task
            task.resume()
            receiveLive()
        }

        func receiveLive() {
            guard let task = liveChannelTask else { return }
            task.receive { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let message):
                        self?.liveChannelAttempts = 0
                        self?.handleLive(message)
                        self?.receiveLive()
                    case .failure:
                        self?.scheduleLiveReconnect()
                    }
                }
            }
        }

        func handleLive(_ message: URLSessionWebSocketTask.Message) {
            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String, type == "voice",
                  let rel = obj["url"] as? String else { return }
            let vid = obj["id"] as? String
            /* the plugin's ack-retry re-sends the same id: never play it twice */
            if let vid, vid == lastVoiceId { return }
            let title = (obj["title"] as? String)?.isEmpty == false
                ? (obj["title"] as! String)
                : "Assistant message"
            /* while the page is alive it plays auto-read itself; we only take
               over when the webview is frozen (locked) */
            if lastVisible { return }
            downloadAndPlay(relative: rel, title: title, voiceId: vid)
        }

        func scheduleLiveReconnect() {
            guard liveChannelEnabled, liveChannelAttempts < 20 else { return }
            liveChannelAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.openLiveChannel()
            }
        }

        func downloadAndPlay(relative rel: String, title: String, voiceId: String?) {
            /* dedupe stands even if the download below fails: a retry of this
               id must never start a second playback */
            if let voiceId { lastVoiceId = voiceId }
            guard let channelURL = liveChannelURL else { return }
            /* derive the origin from the channel URL (strip path + query) */
            var comps = URLComponents(url: channelURL, resolvingAgainstBaseURL: false)
            comps?.path = ""
            comps?.query = nil
            comps?.fragment = nil
            guard let origin = comps?.url,
                  let audioURL = URL(string: rel, relativeTo: origin)?.absoluteURL else { return }
            URLSession.shared.dataTask(with: audioURL) { [weak self] data, _, error in
                DispatchQueue.main.async {
                    guard let self, error == nil, let data = data, !data.isEmpty else { return }
                    self.stopKeepAlive()  /* real audio replaces the silence */
                    self.activateAudioSession(duck: false)
                    self.audioPlayer = try? AVAudioPlayer(data: data)
                    self.audioPlayer?.delegate = self
                    self.audioPlayer?.play()
                    if let voiceId { self.sendVoiceAck(voiceId) }
                    let duration = self.audioPlayer?.duration ?? 0
                    self.updateNowPlaying(title: title, duration: duration)
                    self.refreshNowPlayingElapsed()
                    self.startNowPlayingTimer()
                    self.postJS("window.__phoneTtsState && window.__phoneTtsState('start')")
                }
            }.resume()
        }

        /// Tell the host the audio actually started, so its retry loop can stand down.
        func sendVoiceAck(_ id: String) {
            let ack: [String: Any] = ["type": "voice-ack", "id": id]
            guard let data = try? JSONSerialization.data(withJSONObject: ack),
                  let json = String(data: data, encoding: .utf8) else { return }
            liveChannelTask?.send(.string(json)) { _ in }
        }

        /* ---------- silent keepalive: stops iOS suspending us in background ---------- */

        func startKeepAliveIfNeeded() {
            guard keepAliveOn, isBackground, keepAlivePlayer == nil else { return }
            guard let url = makeSilenceWAV() else { return }
            keepAliveURL = url
            activateAudioSession(duck: true)
            keepAlivePlayer = try? AVAudioPlayer(contentsOf: url)
            keepAlivePlayer?.numberOfLoops = -1
            keepAlivePlayer?.volume = 0.0
            keepAlivePlayer?.play()
        }

        func stopKeepAlive() {
            keepAlivePlayer?.stop()
            keepAlivePlayer = nil
            if let url = keepAliveURL {
                try? FileManager.default.removeItem(at: url)
                keepAliveURL = nil
            }
        }

        /// 1 second of 16 kHz mono PCM16 silence, WAV format.
        func makeSilenceWAV() -> URL? {
            let sampleRate = 16000
            let samples = sampleRate /* 1 second */
            var data = Data()
            func appendAscii(_ str: String) { data.append(str.data(using: .ascii)!) }
            func appendU32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
            func appendU16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
            appendAscii("RIFF"); appendU32(UInt32(36 + samples * 2)); appendAscii("WAVE")
            appendAscii("fmt "); appendU32(16); appendU16(1); appendU16(1)
            appendU32(UInt32(sampleRate)); appendU32(UInt32(sampleRate * 2)); appendU16(2); appendU16(16)
            appendAscii("data"); appendU32(UInt32(samples * 2))
            data.append(Data(count: samples * 2)) /* all zero bytes */
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("keepalive-\(UUID().uuidString).wav")
            do {
                try data.write(to: url)
                return url
            } catch {
                return nil
            }
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
