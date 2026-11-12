import Cocoa
import AVFoundation
import WebKit

// A button whose press and release are reported as they happen, unlike a
// stock NSButton whose target/action only fires once, on release, after an
// internal tracking loop.
class HoldButton: NSButton {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onPress?()
        isHighlighted = true
        guard let window = self.window else { return }
        window.trackEvents(matching: [.leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { [weak self] event, stop in
            guard let self = self, let event = event else { return }
            if event.type == .leftMouseUp {
                self.isHighlighted = false
                self.onRelease?()
                stop.pointee = true
            }
        }
    }
}

class ViewController: NSViewController, WKNavigationDelegate {
    let keychainService = "com.mawst.highspeak"
    let keychainAccount = "groqAPIKey"
    var groqKey: String = ""
    let modelId = "openai/gpt-oss-20b"
    let whisperModelId = "whisper-large-v3-turbo"

    // Show the small gray [DEBUG ...] lines in the transcript.
    let showDebug = true
    // Set to true to send clips to Whisper even when the silence gate rejects
    // them (only useful when debugging the mic).
    let debugBypassGate = false
    // How many past messages (user + assistant) are sent back with each request.
    let maxHistoryMessages = 20

    var webView: WKWebView!
    var pageReady = false
    var pendingJS: [String] = []

    var promptField: NSTextField!
    var sendButton: NSButton!
    var pttButton: HoldButton!
    var statusLabel: NSTextField!

    var speechSynth = NSSpeechSynthesizer()
    var audioRecorder: AVAudioRecorder?
    var recordingURL: URL?
    var isRecording = false
    var meterTimer: Timer?
    var peakDB: Float = -160
    var meterTicks = 0

    var history: [[String: String]] = []
    var usageNote = ""
    var usagePercent: Double = 0

    // Persisted settings (UserDefaults)
    let defaults = UserDefaults.standard
    var chatLog: [[String: Any]] = []
    var restoring = false

    var speakReplies: Bool {
        get { return (defaults.object(forKey: "speakReplies") as? Bool) ?? true }
        set { defaults.set(newValue, forKey: "speakReplies") }
    }
    // Reading code aloud is rarely useful, so it's off unless switched on.
    var speakCode: Bool {
        get { return (defaults.object(forKey: "speakCode") as? Bool) ?? false }
        set { defaults.set(newValue, forKey: "speakCode") }
    }
    var speechRate: Float {
        get { return (defaults.object(forKey: "speechRate") as? Float) ?? 185 }
        set { defaults.set(newValue, forKey: "speechRate") }
    }
    var voiceID: String? {
        get { return defaults.string(forKey: "voice") }
        set { defaults.set(newValue, forKey: "voice") }
    }
    var themeName: String {
        get { return defaults.string(forKey: "theme") ?? "light" }
        set { defaults.set(newValue, forKey: "theme") }
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 660))
        self.view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadPage()
        applySpeechSettings()
        applyTheme()
        addMessage("system", "HighSpeak ready \u{2022} hold the button to talk, or type below")
        restoreChat()
        loadOrPromptForAPIKey()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyTheme()
    }

    // MARK: - System prompt

    // Rebuilt for every request so the model knows today's date. Tweak freely.
    func systemPrompt() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEEE, MMMM d, yyyy"
        let today = df.string(from: Date())
        let tz = TimeZone.current.identifier
        let region = Locale.current.regionCode ?? "US"
        return "You are HighSpeak, a voice assistant running on a vintage Mac. "
            + "Today is \(today) (time zone \(tz), region \(region)). "
            + "Your replies are read aloud, so keep them to one to three short, conversational sentences with no markdown. "
            + "Only use markdown (lists, tables, code blocks) when the user explicitly asks for structured content, a comparison, or code. "
            + "Always put code, markup, configuration and shell commands inside a fenced code block with a language tag."
    }

    // MARK: - API key onboarding (Keychain)

    func loadOrPromptForAPIKey() {
        if let saved = KeychainHelper.load(service: keychainService, account: keychainAccount), !saved.isEmpty {
            groqKey = saved
        } else {
            sendButton.isEnabled = false
            pttButton.isEnabled = false
            promptForAPIKey(forceChange: false)
        }
    }

    @objc func promptForAPIKeyMenuAction() {
        promptForAPIKey(forceChange: true)
    }

    func promptForAPIKey(forceChange: Bool) {
        let alert = NSAlert()
        alert.messageText = forceChange ? "Update Groq API Key" : "Enter your Groq API Key"
        alert.informativeText = "Get one at console.groq.com. It's stored in your macOS Keychain, not in the app itself."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        if forceChange { input.stringValue = groqKey }
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            if !forceChange && groqKey.isEmpty {
                addMessage("system", "No API key set \u{2014} replies are disabled until one is entered (HighSpeak menu > Set Groq API Key).")
            }
            return
        }

        let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            promptForAPIKey(forceChange: forceChange)
            return
        }
        KeychainHelper.save(key: key, service: keychainService, account: keychainAccount)
        groqKey = key
        sendButton.isEnabled = true
        pttButton.isEnabled = true
        setReadyStatus()
        addMessage("system", "API key saved to Keychain.")
    }

    // MARK: - UI

    func setupUI() {
        // Transcript (HTML)
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        // Bottom bar (native, with the standard light titlebar material)
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(line)

        statusLabel = NSTextField(labelWithString: "Ready \u{2022} \(modelId)")
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(statusLabel)

        promptField = NSTextField()
        promptField.placeholderString = "Type a message..."
        promptField.bezelStyle = .roundedBezel
        promptField.font = NSFont.systemFont(ofSize: 13)
        promptField.target = self
        promptField.action = #selector(sendTyped)
        promptField.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(promptField)

        sendButton = NSButton()
        sendButton.title = "Send"
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sendTyped)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(sendButton)

        pttButton = HoldButton()
        pttButton.title = "Hold to Talk (Voice)"
        pttButton.bezelStyle = .rounded
        pttButton.onPress = { [weak self] in self?.pttDown() }
        pttButton.onRelease = { [weak self] in self?.pttUp() }
        pttButton.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(pttButton)

        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 440),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),

            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bar.topAnchor),

            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 76),

            line.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.topAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),

            statusLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: bar.topAnchor, constant: 8),

            promptField.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            promptField.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            promptField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),

            sendButton.centerYAnchor.constraint(equalTo: promptField.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 64),
            sendButton.trailingAnchor.constraint(equalTo: pttButton.leadingAnchor, constant: -8),

            pttButton.centerYAnchor.constraint(equalTo: promptField.centerYAnchor),
            pttButton.widthAnchor.constraint(equalToConstant: 160),
            pttButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16)
        ])
    }

    // MARK: - Transcript (WKWebView)

    func loadPage() {
        var markedJS = ""
        if let data = Data(base64Encoded: markedJSBase64),
           let js = String(data: data, encoding: .utf8) {
            markedJS = js
        }
        let html = chatPageHTML.replacingOccurrences(of: "/*MARKED_JS*/", with: markedJS)
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        for js in pendingJS {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        pendingJS.removeAll()
    }

    // Links in replies open in the default browser, never inside the app.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func runJS(_ js: String) {
        if pageReady {
            webView.evaluateJavaScript(js, completionHandler: nil)
        } else {
            pendingJS.append(js)
        }
    }

    // JSON-encode a string so it can be dropped safely into a JS call.
    func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
              let str = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(str.dropFirst().dropLast())
    }

    // role: "user", "assistant", "system" or "debug"
    func addMessage(_ role: String, _ text: String, voice: Bool = false) {
        let r = jsString(role)
        let t = jsString(text)
        let v = voice ? "true" : "false"
        runJS("addMessage(\(r), \(t), \(v));")
        if !restoring && (role == "user" || role == "assistant") {
            chatLog.append(["role": role, "text": text, "voice": voice])
            if chatLog.count > 300 { chatLog.removeFirst(chatLog.count - 300) }
            defaults.set(chatLog, forKey: "chatLog")
        }
    }

    func debugLine(_ text: String) {
        if showDebug { addMessage("debug", text) }
    }

    func showTyping() {
        runJS("showTyping();")
    }

    func hideTyping() {
        runJS("hideTyping();")
    }

    // MARK: - Typed input

    @objc func sendTyped() {
        let text = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, sendButton.isEnabled else { return }
        promptField.stringValue = ""
        addMessage("user", text)
        statusLabel.stringValue = "Thinking..."
        callGroq(prompt: text)
    }

    // MARK: - Voice input (record -> Groq Whisper transcription -> callGroq)

    @objc func pttDown() {
        if speechSynth.isSpeaking { speechSynth.stopSpeaking() }
        startRecording()
    }

    func startRecording() {
        // Unique file per recording so a failed recording can never cause an
        // old clip to be re-sent to Whisper.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs_\(UUID().uuidString).m4a")
        recordingURL = tempURL
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            let rec = try AVAudioRecorder(url: tempURL, settings: settings)
            rec.isMeteringEnabled = true
            guard rec.record() else {
                addMessage("error", "Microphone error\nThe recorder failed to start")
                recordingURL = nil
                return
            }
            audioRecorder = rec
            isRecording = true
            peakDB = -160
            meterTicks = 0

            // Track the loudest moment of the clip so we can discard silence.
            // Added to .common because HoldButton tracks the mouse in
            // eventTracking mode, where a default-mode timer would not fire.
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self = self, let r = self.audioRecorder else { return }
                r.updateMeters()
                self.meterTicks += 1
                self.peakDB = max(self.peakDB, r.peakPower(forChannel: 0))
            }
            RunLoop.main.add(t, forMode: .common)
            meterTimer = t

            pttButton.title = "Listening..."
            statusLabel.stringValue = "Listening..."
        } catch {
            addMessage("error", "Microphone error\n\(error.localizedDescription)")
        }
    }

    func pttUp() {
        guard isRecording else { return }
        isRecording = false
        meterTimer?.invalidate()
        meterTimer = nil
        pttButton.title = "Hold to Talk (Voice)"

        let secs = audioRecorder?.currentTime ?? 0
        audioRecorder?.stop()
        audioRecorder = nil

        var fileBytes = 0
        if let u = recordingURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
           let size = attrs[.size] as? NSNumber {
            fileBytes = size.intValue
        }
        // If the meter timer never ticked we can't judge loudness, so only
        // the duration check applies in that case.
        let gateOK = secs > 0.4 && (meterTicks == 0 || peakDB > -45)
        let secsStr = String(format: "%.2f", secs)
        let peakStr = String(format: "%.1f", peakDB)
        let gateStr = gateOK ? "pass" : "reject"
        debugLine("[DEBUG secs=\(secsStr) peak=\(peakStr)dB ticks=\(meterTicks) bytes=\(fileBytes) gate=\(gateStr)]")

        // Whisper hallucinates "Thank you." on silence or very short clips,
        // so normally don't send those at all.
        guard let url = recordingURL, (gateOK || debugBypassGate) else {
            setReadyStatus()
            addMessage("system", "Didn't catch that \u{2014} try again (is the mic muted?)")
            if let u = recordingURL { try? FileManager.default.removeItem(at: u) }
            return
        }
        statusLabel.stringValue = "Transcribing..."
        transcribeAudio(fileURL: url)
    }

    func transcribeAudio(fileURL: URL) {
        guard let audioData = try? Data(contentsOf: fileURL) else {
            addMessage("error", "Transcription failed\nCould not read the recording")
            statusLabel.stringValue = "Error"
            return
        }
        let url = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("Bearer \(groqKey)", forHTTPHeaderField: "Authorization")
        let boundary = "Boundary-\(UUID().uuidString)"
        req.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("model", whisperModelId)
        appendField("language", "en")
        appendField("temperature", "0")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, response, error in
            // Audio is already in memory; clean up the temp file.
            try? FileManager.default.removeItem(at: fileURL)

            if let error = error {
                DispatchQueue.main.async {
                    self.addMessage("error", "Transcription failed (network)\n\(error.localizedDescription)")
                    self.statusLabel.stringValue = "Error"
                }
                return
            }
            guard let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                DispatchQueue.main.async {
                    self.addMessage("error", "Transcription failed\nCould not read the response from Groq")
                    self.statusLabel.stringValue = "Error"
                }
                return
            }
            if let text = json["text"] as? String {
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    DispatchQueue.main.async {
                        self.addMessage("user", clean, voice: true)
                        self.statusLabel.stringValue = "Thinking..."
                        self.callGroq(prompt: clean)
                    }
                    return
                }
            }
            let raw = String(data: data, encoding: .utf8) ?? "unreadable"
            DispatchQueue.main.async {
                self.addMessage("error", "Transcription failed\n\(raw)")
                self.statusLabel.stringValue = "Error"
            }
        }.resume()
    }

    // MARK: - Chat completion

    func callGroq(prompt: String, attempt: Int = 0) {
        showTyping()

        var messages: [[String: String]] = [["role": "system", "content": systemPrompt()]]
        messages.append(contentsOf: history)
        messages.append(["role": "user", "content": prompt])

        let url = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("Bearer \(groqKey)", forHTTPHeaderField: "Authorization")
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        // gpt-oss is a reasoning model: a low reasoning effort and a larger
        // token budget keep the reasoning from eating the visible reply.
        let body: [String: Any] = [
            "model": modelId,
            "messages": messages,
            "max_tokens": 1000,
            "reasoning_effort": "low"
        ]
        req.httpBody = try! JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, response, error in
            let http = response as? HTTPURLResponse
            if let http = http { self.updateUsage(from: http) }

            if let http = http, http.statusCode == 429 {
                let retry = self.headerValue(http, "retry-after") ?? "60"
                DispatchQueue.main.async {
                    self.addMessage("error", "Rate limit reached\nGroq asked us to wait \(retry)s before trying again.")
                    self.statusLabel.stringValue = "Rate limited"
                    self.pttButton.isEnabled = false
                    self.sendButton.isEnabled = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + (Double(retry) ?? 60)) {
                        self.pttButton.isEnabled = true
                        self.sendButton.isEnabled = true
                        self.setReadyStatus()
                    }
                }
                return
            }
            if let error = error {
                DispatchQueue.main.async {
                    self.addMessage("error", "Network error\n\(error.localizedDescription)")
                    self.statusLabel.stringValue = "Error"
                }
                return
            }
            guard let responseData = data else {
                DispatchQueue.main.async {
                    self.addMessage("error", "No data returned\nGroq sent an empty response")
                    self.statusLabel.stringValue = "Error"
                }
                return
            }
            let jsonAny = try? JSONSerialization.jsonObject(with: responseData, options: [])
            let json = jsonAny as? [String: Any]

            var reply: String? = nil
            var recovered = false
            if let choices = json?["choices"] as? [[String: Any]],
                let msg = choices.first?["message"] as? [String: Any],
                let c = msg["content"] as? String,
                !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reply = c
            } else if let err = json?["error"] as? [String: Any] {
                if let r = self.recoverFailedGeneration(err) {
                    // gpt-oss sometimes wraps its answer in a fake tool call and
                    // Groq rejects it, but the text is inside the error.
                    reply = r
                    recovered = true
                } else if (err["code"] as? String) == "tool_use_failed" && attempt == 0 {
                    DispatchQueue.main.async {
                        self.debugLine("[DEBUG tool_use_failed, retrying once]")
                        self.callGroq(prompt: prompt, attempt: 1)
                    }
                    return
                }
            }

            guard let content = reply else {
                DispatchQueue.main.async {
                    var title = "The model returned an unexpected response"
                    var details = String(data: responseData, encoding: .utf8) ?? "unreadable"
                    if let err = json?["error"] as? [String: Any] {
                        title = "Groq returned an error"
                        let code = err["code"] as? String ?? "unknown"
                        let message = err["message"] as? String ?? ""
                        details = "code: \(code)\n\(message)"
                    }
                    self.addMessage("error", title + "\n" + details)
                    self.statusLabel.stringValue = "Error"
                }
                return
            }
            DispatchQueue.main.async {
                if recovered { self.debugLine("[DEBUG recovered reply from tool-call error]") }
                self.history.append(["role": "user", "content": prompt])
                self.history.append(["role": "assistant", "content": content])
                if self.history.count > self.maxHistoryMessages {
                    self.history.removeFirst(self.history.count - self.maxHistoryMessages)
                }
                self.addMessage("assistant", content)
                if self.speakReplies {
                    self.speechSynth.startSpeaking(self.speakable(content, includeCode: self.speakCode))
                }
                self.setReadyStatus()
            }
        }.resume()
    }

    // The answer text is inside error.failed_generation, which holds a JSON
    // string like {"name":"assistant","arguments":{"response":"..."}}.
    func recoverFailedGeneration(_ err: [String: Any]) -> String? {
        guard let fg = err["failed_generation"] as? String,
              let data = fg.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        var args: Any? = (obj as? [String: Any])?["arguments"]
        if let str = args as? String, let d = str.data(using: .utf8) {
            args = try? JSONSerialization.jsonObject(with: d, options: [])
        }
        guard let dict = args as? [String: Any] else { return nil }
        if let r = dict["response"] as? String,
           !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return r }
        for (_, v) in dict {
            if let str = v as? String,
               !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return str }
        }
        return nil
    }

    // MARK: - Usage indicator

    func headerValue(_ http: HTTPURLResponse, _ name: String) -> String? {
        for (k, v) in http.allHeaderFields {
            if let key = k as? String, key.lowercased() == name, let val = v as? String { return val }
        }
        return nil
    }

    // Groq's x-ratelimit-*-requests headers always describe requests per DAY
    // for the model just used (tokens per minute is a separate, shorter window).
    func updateUsage(from http: HTTPURLResponse) {
        guard let limStr = headerValue(http, "x-ratelimit-limit-requests"),
              let remStr = headerValue(http, "x-ratelimit-remaining-requests"),
              let limit = Double(limStr), let remaining = Double(remStr), limit > 0 else { return }
        let pct = max(0, min(100, (limit - remaining) / limit * 100))
        DispatchQueue.main.async {
            self.usagePercent = pct
            let pctStr = (pct > 0 && pct < 1) ? "<1%" : String(format: "%.0f%%", pct)
            self.usageNote = "\(pctStr) of today's requests used"
        }
    }

    func setReadyStatus() {
        var text = "Ready \u{2022} \(modelId)"
        if !usageNote.isEmpty { text += " \u{2022} \(usageNote)" }
        statusLabel.stringValue = text
        if usagePercent >= 95 {
            statusLabel.textColor = NSColor.systemRed
        } else if usagePercent >= 80 {
            statusLabel.textColor = NSColor.systemOrange
        } else {
            statusLabel.textColor = NSColor.secondaryLabelColor
        }
    }

    // MARK: - Settings, appearance and persistence

    func applySpeechSettings() {
        // Set the voice first: changing voice resets the rate.
        if let id = voiceID, !id.isEmpty {
            _ = speechSynth.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: id))
        }
        speechSynth.rate = speechRate
    }

    func applyTheme() {
        let dark = (themeName == "dark")
        let name = jsString(themeName)
        runJS("setTheme(\(name));")
        guard let window = view.window else { return }
        window.appearance = dark ? NSAppearance(named: NSAppearance.Name.vibrantDark) : nil
        window.backgroundColor = dark
            ? NSColor(calibratedRed: 28.0/255.0, green: 28.0/255.0, blue: 30.0/255.0, alpha: 1)
            : NSColor(calibratedRed: 245.0/255.0, green: 245.0/255.0, blue: 247.0/255.0, alpha: 1)
    }

    func restoreChat() {
        guard let saved = defaults.array(forKey: "chatLog") as? [[String: Any]], !saved.isEmpty else { return }
        restoring = true
        for m in saved {
            guard let role = m["role"] as? String, let text = m["text"] as? String else { continue }
            addMessage(role, text, voice: (m["voice"] as? Bool) ?? false)
        }
        restoring = false
        chatLog = saved
        history = saved.compactMap { m -> [String: String]? in
            guard let role = m["role"] as? String, let text = m["text"] as? String else { return nil }
            return ["role": role, "content": text]
        }
        if history.count > maxHistoryMessages {
            history.removeFirst(history.count - maxHistoryMessages)
        }
        addMessage("system", "Previous conversation restored \u{2022} Chat menu > Clear Chat to start fresh")
    }

    @objc func clearChatAction() {
        speechSynth.stopSpeaking()
        chatLog = []
        history = []
        defaults.removeObject(forKey: "chatLog")
        runJS("clearChat();")
        addMessage("system", "Chat cleared")
    }

    @objc func speakRepliesAction() {
        speakReplies = !speakReplies
        if !speakReplies { speechSynth.stopSpeaking() }
    }

    @objc func speakCodeAction() {
        speakCode = !speakCode
    }

    @objc func rateAction(_ sender: NSMenuItem) {
        speechRate = Float(sender.tag)
        applySpeechSettings()
        speechSynth.stopSpeaking()
        speechSynth.startSpeaking("This is the new speaking rate.")
    }

    @objc func voiceAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        voiceID = id
        applySpeechSettings()
        speechSynth.stopSpeaking()
        speechSynth.startSpeaking("Hello, this is HighSpeak.")
    }

    @objc func themeAction(_ sender: NSMenuItem) {
        themeName = (sender.tag == 1) ? "dark" : "light"
        applyTheme()
    }

    // Puts the checkmarks on the Speech / View menu items.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(speakRepliesAction) {
            item.state = speakReplies ? .on : .off
        } else if item.action == #selector(speakCodeAction) {
            item.state = speakCode ? .on : .off
        } else if item.action == #selector(themeAction(_:)) {
            let darkTag = (themeName == "dark") ? 1 : 0
            item.state = (item.tag == darkTag) ? .on : .off
        } else if item.action == #selector(rateAction(_:)) {
            item.state = (Float(item.tag) == speechRate) ? .on : .off
        } else if item.action == #selector(voiceAction(_:)) {
            let current = voiceID ?? speechSynth.voice()?.rawValue
            item.state = ((item.representedObject as? String) == current) ? .on : .off
        }
        return true
    }

    // MARK: - Speech cleanup

    // Strip markdown so the speech synthesizer doesn't read out symbols,
    // and skip code/tables (they're on screen).
    func speakable(_ md: String, includeCode: Bool = false) -> String {
        var s = md
        func sub(_ pattern: String, _ template: String) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let range = NSRange(location: 0, length: (s as NSString).length)
            s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
        }
        let hadCode = s.contains("```")
        let hadTable = s.contains("|---") || s.contains("| ---") || s.contains("|:--")
        if includeCode {
            sub("```[^\\n]*\\n?", " ")          // drop just the fence lines, keep the code
        } else {
            sub("```[\\s\\S]*?```", " ")
        }
        sub("(?m)^\\s*\\|.*$", "")
        sub("\\[([^\\]]+)\\]\\([^)]*\\)", "$1")
        sub("(?m)^\\s{0,3}#{1,6}\\s*", "")
        sub("(?m)^\\s*[-*+]\\s+", "")
        sub("(?m)^\\s*\\d+\\.\\s+", "")
        sub("[*_`~]+", "")
        sub("\\n{2,}", "\n")
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if hadTable { out += " I put a table on the screen." }
        if hadCode && !includeCode { out += " The code is on the screen." }
        return out.isEmpty ? "Here you go." : out
    }
}
