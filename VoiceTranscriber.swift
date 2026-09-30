// VoiceTranscriber — press ⌥Space anywhere to record, press again to stop.
// Audio is transcribed by OpenAI (gpt-4o-transcribe) and the text is pasted
// straight into the frontmost app (and left on the clipboard). Esc cancels.
//
// Notes: tap ⌥N while recording to ALSO keep the dictation as a note (it still
// pastes as normal). ⌥N while idle opens the notes list — click a note to copy.
// Notes live in ~/.config/voice-transcriber/notes.json.
//
// Config: ~/.config/voice-transcriber/config.json
//   { "openaiKey", "model", "language"?, "autoPaste"?, "maxSeconds"?, "vocabulary"?,
//     "replacements"?: { "Chat GPT": "ChatGPT" } }

import AppKit
import AVFoundation
import AudioToolbox
import Carbon.HIToolbox
import CoreAudio

// MARK: - Config

struct Config: Decodable {
    var openaiKey: String
    var model: String
    var language: String?
    var autoPaste: Bool?
    var maxSeconds: Double?
    /// Names the model would otherwise mangle. Not an instruction — a spelling
    /// hint the transcriber biases towards. Edit freely as new clients appear.
    var vocabulary: [String]?
    /// Hard spelling fixes applied to every transcript, e.g. {"Chat GPT": "ChatGPT"}.
    /// Whole-word, case-insensitive; the vocabulary hint alone isn't a guarantee.
    var replacements: [String: String]?

    static func load() -> Config {
        let path = ("~/.config/voice-transcriber/config.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path) else {
            fputs("FATAL: missing config at \(path)\n", stderr)
            exit(1)
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            fputs("FATAL: bad config JSON at \(path): \(error)\n", stderr)
            exit(1)
        }
    }
}

/// Reloaded in place when Settings saves, so changes apply from the next take.
var config = Config.load()

// MARK: - Notes store

struct Note: Codable {
    let id: String
    let text: String
    let createdAt: Date
    /// The app the dictation was pasted into — useful context when reading back.
    let app: String?
}

/// Plain JSON file next to the config: readable, hand-editable, trivially backed up.
final class NotesStore {
    static let shared = NotesStore()
    let url = URL(fileURLWithPath: ("~/.config/voice-transcriber/notes.json" as NSString).expandingTildeInPath)
    private(set) var notes: [Note] = [] // newest first

    private init() { reload() }

    func reload() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = FileManager.default.contents(atPath: url.path),
           let decoded = try? dec.decode([Note].self, from: data) {
            notes = decoded.sorted { $0.createdAt > $1.createdAt }
        } else {
            notes = []
        }
    }

    func add(_ text: String, app: String?) {
        reload() // respect any hand edits made since we last looked
        notes.insert(Note(id: UUID().uuidString, text: text, createdAt: Date(), app: app), at: 0)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(notes) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Warm amber for the note tag — reads as "flagged", distinct from the red meter
/// and the blue/green status icons.
let noteAmber = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.32, alpha: 1)

let logFileURL = URL(fileURLWithPath: ("~/Library/Logs/voice-transcriber.log" as NSString).expandingTildeInPath)

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "[\(f.string(from: Date()))] \(msg)\n"
    print(line, terminator: "")
    fflush(stdout)
    // Launched via LaunchServices (`open`), stdout doesn't reach the launchd log
    // file — append directly.
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logFileURL)
        }
    }
}

// MARK: - Type

/// SF Rounded — softer than the default system face, better suited to a HUD pill.
func rounded(_ size: CGFloat, _ weight: NSFont.Weight, monoDigits: Bool = false) -> NSFont {
    let base = monoDigits
        ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        : NSFont.systemFont(ofSize: size, weight: weight)
    guard let d = base.fontDescriptor.withDesign(.rounded),
          let f = NSFont(descriptor: d, size: size) else { return base }
    return f
}

// MARK: - Chime (synthesized, so it can't be mistaken for a system alert)

final class Chime {
    static let shared = Chime()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?

    private init() {
        let sr = 44100.0
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(sr * 0.18))
        else { return }
        buf.frameLength = buf.frameCapacity
        guard let ch = buf.floatChannelData?[0] else { return }

        // Two soft partials a fifth apart (C6 + G6) with a fast exponential decay:
        // reads as a light "tick–shimmer" rather than an alert. The 4 ms fade-in
        // removes the click a raw sine start would produce.
        for i in 0..<Int(buf.frameLength) {
            let t = Double(i) / sr
            let attack = min(1.0, t / 0.004)
            let decay = exp(-t * 24.0)
            let s = sin(2 * .pi * 1046.5 * t) * 0.72 + sin(2 * .pi * 1568.0 * t) * 0.28
            ch[i] = Float(s * attack * decay * 0.20)
        }
        buffer = buf
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        try? engine.start()
    }

    func play() {
        guard let buf = buffer else { return }
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buf, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }
}

// MARK: - Live level meter

final class LevelMeterView: NSView {
    private var bars: [CALayer] = []
    private var heights: [CGFloat] = []
    private let shape: [CGFloat] = [0.5, 0.78, 1.0, 0.8, 0.55] // centre bar tallest
    private let barW: CGFloat = 3, gap: CGFloat = 3, maxH: CGFloat = 17, minH: CGFloat = 3
    private var phase: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in shape {
            let l = CALayer()
            l.backgroundColor = NSColor.systemRed.cgColor
            l.cornerRadius = barW / 2
            layer?.addSublayer(l)
            bars.append(l)
            heights.append(minH)
        }
        translatesAutoresizingMaskIntoConstraints = false
        let total = CGFloat(shape.count) * barW + CGFloat(shape.count - 1) * gap
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: total),
            heightAnchor.constraint(equalToConstant: maxH),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// level: 0…1 from the mic. Bars ease toward their target instead of snapping,
    /// which is what makes it read as fluid rather than twitchy.
    func update(level: CGFloat) {
        phase += 0.22
        CATransaction.begin()
        CATransaction.setDisableActions(true) // we do our own easing at 30fps
        for (i, bar) in bars.enumerated() {
            let wobble = 1 + 0.16 * sin(phase + CGFloat(i) * 1.1)
            let target = max(minH, min(maxH, level * shape[i] * wobble * maxH))
            heights[i] += (target - heights[i]) * 0.4
            let h = heights[i]
            let x = CGFloat(i) * (barW + gap)
            bar.frame = CGRect(x: x, y: (bounds.height - h) / 2, width: barW, height: h)
        }
        CATransaction.commit()
    }

    func reset() {
        for i in heights.indices { heights[i] = minH }
        update(level: 0)
    }

    /// Red for a plain dictation, amber once it has been tagged as a note.
    func tint(_ color: NSColor) {
        for bar in bars { bar.backgroundColor = color.cgColor }
    }
}

// MARK: - HUD (small pill at the top-middle of the screen)

final class HUD {
    static let shared = HUD()

    enum State {
        case recording(elapsed: TimeInterval, level: CGFloat, note: Bool)
        case transcribing
        case done(String)      // short confirmation, e.g. "Pasted ✓"
        case error(String)
    }

    private var panel: NSPanel?
    private var blur: NSView?
    private var content: NSStackView?
    private var meter: LevelMeterView?
    private var icon: NSImageView?
    private var label: NSTextField?
    private var chip: NSView?
    private var chipLabel: NSTextField?
    private var noteTag: NSView?
    /// Short name of the mic the current take records from, shown in the chip.
    private var micName = "Mic"

    /// "MacBook Pro Microphone" → "MacBook Pro Mic"; long names are capped.
    func setMic(_ name: String) {
        var s = name
        if s.hasSuffix(" Microphone") { s = String(s.dropLast("rophone".count)) }
        if s.count > 30 { s = String(s.prefix(29)) + "…" }
        micName = s
        chipLabel?.stringValue = s
    }
    private var hideTimer: Timer?
    private var lastKind = ""
    private var contentCenterY: NSLayoutConstraint?
    /// Which layout the current panel was built for. The notch slab and the
    /// free-floating pill have different corner masking, shadow and content
    /// offsets, so moving between the built-in display and an external one has
    /// to rebuild the panel rather than just reposition it.
    private var builtForNotch: Bool?

    /// Notch geometry of the built-in display, if this Mac has one.
    /// `height` is the notch's depth; `width` the black cutout's width.
    private var notch: (height: CGFloat, width: CGFloat)? {
        guard let screen = NSScreen.main else { return nil }
        let h = screen.safeAreaInsets.top
        guard h > 0 else { return nil } // external monitor / no notch
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let w = screen.frame.width - left - right
        return (h, w > 0 ? w : 200)
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 292, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // In notch mode the window shadow paints a 2px grey rim (measured RGB
        // 51,51,51) along the top edge, which reads as a border and makes the
        // slab look detached from the screen edge. No shadow = seamless black.
        panel.hasShadow = notch == nil
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Pitch black to match the notch cutout exactly — no vibrancy, since any
        // translucency would let the wallpaper through and break the illusion.
        let blur = NSView()
        blur.wantsLayer = true
        blur.layer?.backgroundColor = NSColor.black.cgColor
        blur.layer?.masksToBounds = true
        if notch != nil {
            // Hanging off the notch: square at the top so it fuses with the
            // cutout, rounded only where it emerges below.
            blur.layer?.cornerRadius = 16
            blur.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        } else {
            blur.layer?.cornerRadius = 22      // no notch: free-floating pill
            blur.layer?.borderWidth = 1
            blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        }
        self.blur = blur

        let meter = LevelMeterView(frame: .zero)
        self.meter = meter

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        self.icon = icon

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = rounded(13, .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        self.label = label

        // Quiet chip naming the mic this take is recording from.
        let micIcon = NSImageView(image: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil) ?? NSImage())
        micIcon.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        micIcon.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        micIcon.setContentHuggingPriority(.required, for: .horizontal)
        let chipLabel = NSTextField(labelWithString: micName)
        chipLabel.font = rounded(10.5, .semibold)
        chipLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        chipLabel.lineBreakMode = .byTruncatingTail
        self.chipLabel = chipLabel
        let chipRow = NSStackView(views: [micIcon, chipLabel])
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        chipRow.orientation = .horizontal
        chipRow.alignment = .centerY
        chipRow.spacing = 4
        let chip = NSView()
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        chip.layer?.cornerRadius = 6
        chip.addSubview(chipRow)
        NSLayoutConstraint.activate([
            chipRow.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 7),
            chipRow.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -7),
            chipRow.topAnchor.constraint(equalTo: chip.topAnchor, constant: 3),
            chipRow.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -3),
        ])
        self.chip = chip

        // "Note" tag — appears next to the meter once ⌥N has flagged the take.
        let tagLabel = NSTextField(labelWithString: "Note")
        tagLabel.translatesAutoresizingMaskIntoConstraints = false
        tagLabel.font = rounded(10.5, .bold)
        tagLabel.textColor = noteAmber
        let tag = NSView()
        tag.translatesAutoresizingMaskIntoConstraints = false
        tag.wantsLayer = true
        tag.layer?.backgroundColor = noteAmber.withAlphaComponent(0.16).cgColor
        tag.layer?.cornerRadius = 6
        tag.addSubview(tagLabel)
        NSLayoutConstraint.activate([
            tagLabel.leadingAnchor.constraint(equalTo: tag.leadingAnchor, constant: 7),
            tagLabel.trailingAnchor.constraint(equalTo: tag.trailingAnchor, constant: -7),
            tagLabel.topAnchor.constraint(equalTo: tag.topAnchor, constant: 3),
            tagLabel.bottomAnchor.constraint(equalTo: tag.bottomAnchor, constant: -3),
        ])
        tag.isHidden = true
        self.noteTag = tag

        let content = NSStackView(views: [meter, noteTag!, icon, label, chip])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 9
        self.content = content

        blur.addSubview(content)
        // In notch mode the panel's top slab sits behind the notch itself, so the
        // content is pushed down into the visible band below it. (AppKit centerY
        // constants read positive-downwards here — verified on screen, not assumed.)
        let yOffset = notch.map { $0.height / 2 } ?? 0
        let centerY = content.centerYAnchor.constraint(equalTo: blur.centerYAnchor, constant: yOffset)
        contentCenterY = centerY
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            centerY,
            content.leadingAnchor.constraint(greaterThanOrEqualTo: blur.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(lessThanOrEqualTo: blur.trailingAnchor, constant: -14),
        ])

        panel.contentView = blur
        self.panel = panel
        self.builtForNotch = notch != nil
    }

    /// Drop the panel so the next show() rebuilds it for the current display.
    private func destroyPanel() {
        panel?.orderOut(nil)
        panel = nil
        blur = nil
        content = nil
        meter = nil
        icon = nil
        label = nil
        chip = nil
        chipLabel = nil
        noteTag = nil
        contentCenterY = nil
        builtForNotch = nil
        currentWidth = 0
        lastKind = ""
    }

    /// Displays changed (plugged in, unplugged, resolution or arrangement
    /// change): the cached geometry is meaningless now.
    @objc func screensChanged() {
        destroyPanel()
    }

    private var currentWidth: CGFloat = 0

    private func position(width: CGFloat, animated: Bool) {
        guard let panel = panel, let screen = NSScreen.main else { return }
        // Called ~30x/sec while recording — only touch the window when the width
        // actually changes.
        guard width != currentWidth else { return }
        let firstShow = currentWidth == 0
        currentWidth = width

        let target: NSRect
        if let notch = notch {
            // Grow out of the notch: flush with the physical top edge, centred on
            // the cutout, and never narrower than the notch itself — otherwise the
            // black slab would read as a separate object instead of an extension.
            let w = max(width, notch.width + 16)
            let size = NSSize(width: w, height: notch.height + 40)
            target = NSRect(
                origin: NSPoint(x: screen.frame.midX - w / 2, y: screen.frame.maxY - size.height),
                size: size)
        } else {
            let vf = screen.visibleFrame
            let size = NSSize(width: width, height: 44)
            target = NSRect(
                origin: NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 12),
                size: size)
        }
        if animated && !firstShow {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// Two-tone timer: seconds carry the weight, milliseconds recede.
    private func timerText(_ t: TimeInterval) -> NSAttributedString {
        let mins = Int(t) / 60, secs = Int(t) % 60
        let ms = Int((t * 1000).truncatingRemainder(dividingBy: 1000))
        let s = NSMutableAttributedString(
            string: String(format: "%d:%02d", mins, secs),
            attributes: [.font: rounded(15, .semibold, monoDigits: true),
                         .foregroundColor: NSColor.white.withAlphaComponent(0.95)])
        s.append(NSAttributedString(
            string: String(format: ".%03d", ms),
            attributes: [.font: rounded(11.5, .medium, monoDigits: true),
                         .foregroundColor: NSColor.white.withAlphaComponent(0.42)]))
        return s
    }

    func show(_ state: State) {
        if panel != nil, builtForNotch != (notch != nil) { destroyPanel() }
        if panel == nil { buildPanel() }
        hideTimer?.invalidate()

        let kind: String
        switch state {
        case .recording(_, _, let note): kind = note ? "recording-note" : "recording"
        case .transcribing: kind = "transcribing"
        case .done: kind = "done"
        case .error: kind = "error"
        }
        let changed = kind != lastKind
        lastKind = kind

        switch state {
        case .recording(let t, let level, let note):
            meter?.isHidden = false
            chip?.isHidden = false
            icon?.isHidden = true
            noteTag?.isHidden = !note
            if changed { meter?.tint(note ? noteAmber : .systemRed) }
            meter?.update(level: level)
            label?.attributedStringValue = timerText(t)
            // Sized to the content, since the mic chip's name varies per device.
            let fit = ceil(content?.fittingSize.width ?? 264) + 32
            position(width: max(fit, 220), animated: true)
        case .transcribing:
            meter?.isHidden = true
            chip?.isHidden = true
            noteTag?.isHidden = true
            icon?.isHidden = false
            icon?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
            icon?.contentTintColor = NSColor.systemBlue
            label?.attributedStringValue = NSAttributedString(
                string: "Transcribing…",
                attributes: [.font: rounded(13, .semibold),
                             .foregroundColor: NSColor.white.withAlphaComponent(0.9)])
            position(width: 160, animated: true)
        case .done(let text):
            meter?.isHidden = true
            chip?.isHidden = true
            noteTag?.isHidden = true
            icon?.isHidden = false
            icon?.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            icon?.contentTintColor = NSColor.systemGreen
            label?.attributedStringValue = doneText(text)
            position(width: 210, animated: true)
            autoHide(after: 1.6)
        case .error(let text):
            meter?.isHidden = true
            chip?.isHidden = true
            noteTag?.isHidden = true
            icon?.isHidden = false
            icon?.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            icon?.contentTintColor = NSColor.systemRed
            label?.attributedStringValue = NSAttributedString(
                string: text,
                attributes: [.font: rounded(12.5, .medium),
                             .foregroundColor: NSColor.white.withAlphaComponent(0.9)])
            position(width: 320, animated: true)
            autoHide(after: 3.5)
        }

        if let panel = panel, !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel?.alphaValue = 1
            panel?.orderFrontRegardless()
        }

        // Crossfade only when the state actually changes — never on timer ticks.
        if changed, let content = content {
            content.layer?.removeAnimation(forKey: "fade")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.duration = 0.22
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            content.wantsLayer = true
            content.layer?.add(fade, forKey: "fade")
        }
    }

    /// "Pasted ✓  940 ms" — the latency reads as secondary detail.
    private func doneText(_ text: String) -> NSAttributedString {
        let parts = text.components(separatedBy: "  ")
        let s = NSMutableAttributedString(
            string: parts[0],
            attributes: [.font: rounded(13, .semibold),
                         .foregroundColor: NSColor.white.withAlphaComponent(0.95)])
        if parts.count > 1 {
            s.append(NSAttributedString(
                string: "  " + parts[1...].joined(separator: "  "),
                attributes: [.font: rounded(11.5, .medium, monoDigits: true),
                             .foregroundColor: NSColor.white.withAlphaComponent(0.42)]))
        }
        return s
    }

    func hide() {
        hideTimer?.invalidate()
        guard let panel = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.meter?.reset()
            self?.lastKind = ""
        })
    }

    private func autoHide(after: TimeInterval) {
        hideTimer = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }
}

// MARK: - OpenAI transcription

enum TranscribeResult {
    case success(String)
    case failure(String)
}

func transcribe(fileURL: URL, completion: @escaping (TranscribeResult) -> Void) {
    guard let audio = try? Data(contentsOf: fileURL) else {
        completion(.failure("could not read recording")); return
    }
    let boundary = "vt-\(UUID().uuidString)"
    var body = Data()
    func field(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }
    field("model", config.model)
    field("response_format", "text")
    if let lang = config.language, !lang.isEmpty { field("language", lang) }
    if let vocab = config.vocabulary, !vocab.isEmpty {
        field("prompt", vocab.joined(separator: ", "))
    }
    body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
    body.append(audio)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(config.openaiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    req.timeoutInterval = 30

    let started = Date()
    URLSession.shared.dataTask(with: req) { data, resp, err in
        DispatchQueue.main.async {
            if let err = err {
                completion(TranscribeResult.failure(err.localizedDescription)); return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard (200..<300).contains(code) else {
                completion(.failure("HTTP \(code): \(text.prefix(140))")); return
            }
            log(String(format: "OpenAI round-trip %.0f ms (%d KB audio)",
                       Date().timeIntervalSince(started) * 1000, audio.count / 1024))
            completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }.resume()
}

/// Applies config.replacements as whole-word, case-insensitive swaps.
func applyReplacements(_ text: String) -> String {
    guard let map = config.replacements, !map.isEmpty else { return text }
    var out = text
    for (wrong, right) in map {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: wrong) + "\\b"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
        out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                          withTemplate: NSRegularExpression.escapedTemplate(for: right))
    }
    return out
}

/// True when the transcript is really just the vocabulary hint parroted back
/// (whole, or its opening run of terms) — what gpt-4o-transcribe does with silence.
func isPromptEcho(_ text: String) -> Bool {
    guard let vocab = config.vocabulary, vocab.count >= 3 else { return false }
    func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    // The echo sometimes arrives dressed up ("Context: <your first few names>, …"), so
    // look for the opening run of terms anywhere, not only at the start.
    let t = norm(text)
    let whole = norm(vocab.joined(separator: " "))
    let opening = norm(vocab.prefix(4).joined(separator: " "))
    return t == whole || t.contains(opening)
}

// MARK: - Paste

/// Puts the text on the clipboard and synthesizes cmd+V into `target` — the app
/// that was frontmost when recording started, so the text lands at the cursor you
/// were actually typing at. Returns true if it pasted.
func deliver(_ text: String, into target: NSRunningApplication?) -> Bool {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)

    guard config.autoPaste ?? true, AXIsProcessTrusted() else { return false }

    // Make sure the app you dictated into owns the keystroke. If something else
    // grabbed focus meanwhile (or the HUD nudged it), bring it back first.
    if let app = target, !app.isActive {
        app.activate(options: [])
        usleep(120_000) // let the activation land before the keystroke
    }

    // .privateState so the synthetic ⌘V doesn't inherit modifier keys you may
    // still be physically holding (⌥ from ⌥Space would make it ⌘⌥V).
    let src = CGEventSource(stateID: .privateState)

    // Full sequence including the Command key-up: sending only the V events
    // leaves the target app believing ⌘ is still held, which makes it show
    // link-style hover (hand cursor, highlighted rows) until a real modifier
    // press clears it.
    guard let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
          let vDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
          let vUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false),
          let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Command), keyDown: false)
    else { return false }
    cmdDown.flags = .maskCommand
    vDown.flags = .maskCommand
    vUp.flags = .maskCommand
    cmdUp.flags = []

    // Post straight to the target process when we know it, so the keystroke can't
    // be delivered to whatever else happens to be frontmost at that millisecond.
    let events = [cmdDown, vDown, vUp, cmdUp]
    if let pid = target?.processIdentifier {
        events.forEach { $0.postToPid(pid) }
    } else {
        events.forEach { $0.post(tap: .cghidEventTap) }
    }
    return true
}

// MARK: - Input device (prefer an external mic over the built-in one)

/// macOS switches OUTPUT to a headset automatically but frequently leaves the
/// default INPUT on the built-in mic — so a plugged-in headset mic sits unused.
/// We pick the device ourselves at each take instead of trusting the default.
enum AudioInput {
    struct Device {
        let id: AudioDeviceID
        let name: String
        /// CoreAudio UID — the same string AVCaptureDevice uses as `uniqueID`.
        let uid: String
        let transport: UInt32
        /// The Mac's own mic. A wired headset on the jack shows up as a separate
        /// "External Microphone" device on the same built-in transport, hence the name check.
        var isBuiltInMic: Bool {
            transport == kAudioDeviceTransportTypeBuiltIn && !name.localizedCaseInsensitiveContains("external")
        }
        /// Software devices (BlackHole, Zoom, Teams, aggregates) and Continuity
        /// iPhones/iPads (which appear whenever a phone is nearby or charging on
        /// the cable) are never auto-picked.
        var isPhysical: Bool {
            ![kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
              kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeUnknown,
              kAudioDeviceTransportTypeContinuityCaptureWired,
              kAudioDeviceTransportTypeContinuityCaptureWireless].contains(transport)
        }
    }

    private static func get<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               _ value: inout T) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) == noErr
        }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func inputDevices() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0 else { return nil }
            var name: CFString = "" as CFString
            var transport: UInt32 = 0
            _ = get(id, kAudioObjectPropertyName, &name)
            _ = get(id, kAudioDevicePropertyTransportType, &transport)
            var uid: CFString = "" as CFString
            _ = get(id, kAudioDevicePropertyDeviceUID, &uid)
            return Device(id: id, name: name as String, uid: uid as String, transport: transport)
        }
    }

    static func systemDefault() -> AudioDeviceID? {
        var id: AudioDeviceID = 0
        return get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, &id) ? id : nil
    }

    /// The mic to record from: the system default if it is already an external
    /// one, otherwise the first physical external mic, otherwise the default.
    static func preferred() -> Device? {
        let devices = inputDevices()
        let def = systemDefault()
        let external = devices.filter { $0.isPhysical && !$0.isBuiltInMic }
        if let d = external.first(where: { $0.id == def }) { return d }
        if let d = external.first { return d }
        return devices.first { $0.id == def } ?? devices.first
    }
}

// MARK: - Recorder / state machine

final class Controller: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = Controller()

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              let fmt = AVAudioFormat(streamDescription: &asbd),
              let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)
        else { return }
        pcm.frameLength = frames
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard st == noErr else { return }
        consume(pcm)
    }

    private enum State { case idle, recording, transcribing }
    private var state: State = .idle {
        didSet { MenuBar.shared.setRecording(state == .recording) }
    }
    // AVCaptureSession (rather than AVAudioRecorder) so the input device can be
    // chosen per take. Device selection is a first-class API here; the
    // AVAudioEngine route (kAudioOutputUnitProperty_CurrentDevice) proved
    // unreliable — on the Logi headset it started fine and delivered zero
    // buffers once the device's native rate (44.1 kHz) stopped matching the
    // engine's cached 48 kHz format. The session hands us 16 kHz mono float
    // directly, which streams into an AAC file — same tiny upload as before.
    private var session: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "voice-transcriber.capture")
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter? // only if the session ignores our format request
    private let fileLock = NSLock()
    private var recordingURL: URL?
    private var startedAt = Date()
    private var levelDb: Float = -160
    private var framesWritten: Int64 = 0
    private var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
    private var tickTimer: Timer?
    private var maxTimer: Timer?
    private var escHotKey: EventHotKeyRef?
    /// The app that was frontmost when recording started — where the text belongs.
    private var targetApp: NSRunningApplication?
    /// Set by ⌥N during a take: keep this dictation as a note as well as pasting it.
    private var isNote = false

    func toggle() {
        switch state {
        case .idle: start()
        case .recording: stopAndTranscribe()
        case .transcribing: break // ignore presses while working
        }
    }

    /// ⌥N — context-sensitive: flags the take while recording, opens the notes
    /// list while idle. (The HUD picks the flag up on its next ~33 ms tick.)
    func noteKey() {
        switch state {
        case .recording:
            isNote.toggle()
            log(isNote ? "take tagged as note (⌥N)" : "note tag removed (⌥N)")
        case .idle:
            NotesWindow.shared.toggle()
        case .transcribing:
            break
        }
    }

    func cancel() {
        guard state == .recording else { return }
        teardownRecording()
        state = .idle
        HUD.shared.hide()
        log("recording cancelled (Esc)")
    }

    private func start() {
        // No key yet (fresh install that skipped it): say where to add it rather
        // than recording something that can only come back as a 401.
        if config.openaiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            HUD.shared.show(.error("Add your OpenAI key in Settings"))
            SettingsWindow.shared.open(tab: 1)
            return
        }
        // Dictating with the notes list open: put it away first so the text
        // still lands in the app you were actually working in.
        NotesWindow.shared.close()
        targetApp = NSWorkspace.shared.frontmostApplication
        isNote = false
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vt-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
        ]
        let device = AudioInput.preferred()
        var micName = "system default"
        do {
            // Resolve our CoreAudio pick to its AVCapture twin via the device UID.
            let capture = device.flatMap { AVCaptureDevice(uniqueID: $0.uid) }
                ?? AVCaptureDevice.default(for: .audio)
            guard let cap = capture else {
                throw NSError(domain: "vt", code: 2, userInfo: [NSLocalizedDescriptionKey: "no microphone available"])
            }
            micName = cap.localizedName
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: true)
            audioFile = file
            converter = nil
            recordingURL = url
            levelDb = -160
            framesWritten = 0

            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: cap)
            guard session.canAddInput(input) else { throw NSError(domain: "vt", code: 3) }
            session.addInput(input)
            let output = AVCaptureAudioDataOutput()
            // macOS lets the output do the downmix + resample for us.
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            output.setSampleBufferDelegate(self, queue: captureQueue)
            guard session.canAddOutput(output) else { throw NSError(domain: "vt", code: 4) }
            session.addOutput(output)
            session.startRunning()
            self.session = session
            startedAt = Date()
        } catch {
            HUD.shared.show(.error("Mic failed — is microphone access granted?"))
            log("record start failed: \(error)")
            teardownRecording()
            try? FileManager.default.removeItem(at: url)
            return
        }
        state = .recording
        HUD.shared.setMic(micName)
        HUD.shared.show(.recording(elapsed: 0, level: 0, note: false))
        registerEscape()

        // ~30fps so the millisecond digits run and the meter moves with your voice.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            guard let self = self, self.state == .recording else { return }
            // Speech sits roughly between -50 dB (silence) and -5 dB (loud); map
            // that span to 0…1 and curve it so normal talking fills the meter.
            let db = CGFloat(self.levelDb)
            let level = pow(max(0, min(1, (db + 50) / 45)), 0.85)
            HUD.shared.show(.recording(elapsed: self.elapsed, level: level, note: self.isNote))
        }
        let cap = config.maxSeconds ?? 300
        maxTimer = Timer.scheduledTimer(withTimeInterval: cap, repeats: false) { [weak self] _ in
            log("max duration reached — auto-stopping")
            self?.stopAndTranscribe()
        }
        log("recording started — mic: \(micName)")
    }

    /// Capture-queue callback: meter the buffer and append it to the file.
    /// Normally the session already delivers the file's exact format; if it
    /// doesn't, a converter is built once from whatever arrived.
    private func consume(_ buf: AVAudioPCMBuffer) {
        if let ch = buf.floatChannelData?[0], buf.frameLength > 0 {
            var sum: Float = 0
            let stride = Int(buf.format.channelCount)
            let n = Int(buf.frameLength)
            for i in 0..<n { let s = ch[i * stride]; sum += s * s }
            let rms = (sum / Float(n)).squareRoot()
            let db = 20 * log10(max(rms, 1e-7))
            DispatchQueue.main.async { [weak self] in self?.levelDb = db }
        }
        fileLock.lock(); defer { fileLock.unlock() }
        guard let file = audioFile else { return }
        let outFmt = file.processingFormat
        var toWrite = buf
        if buf.format != outFmt {
            if converter == nil {
                converter = AVAudioConverter(from: buf.format, to: outFmt)
                log(String(format: "session delivered %.0f Hz × %d ch — converting",
                           buf.format.sampleRate, buf.format.channelCount))
            }
            guard let conv = converter else { return }
            let ratio = outFmt.sampleRate / buf.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: capacity) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            if let err = err { log("convert error: \(err.localizedDescription)"); return }
            toWrite = out
        }
        guard toWrite.frameLength > 0 else { return }
        do { try file.write(from: toWrite); framesWritten += Int64(toWrite.frameLength) }
        catch { log("file write error: \(error)") }
    }

    private func stopAndTranscribe() {
        guard state == .recording, let url = recordingURL else { return }
        let duration = elapsed
        let asNote = isNote
        teardownRecording()

        // Sub-half-second recordings are almost always accidental double-presses.
        guard duration > 0.4 else {
            state = .idle
            HUD.shared.hide()
            try? FileManager.default.removeItem(at: url)
            return
        }

        // Nothing reached the file (mic dropped, engine stalled): say so instead
        // of uploading an empty container and getting a cryptic 400 back.
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let captured = Double(framesWritten) / 16000
        guard framesWritten > 0, bytes > 500 else {
            state = .idle
            HUD.shared.show(.error("No audio captured — mic dropped out?"))
            log(String(format: "no audio captured (%lld frames, %d bytes) — take discarded", framesWritten, bytes))
            try? FileManager.default.removeItem(at: url)
            return
        }

        state = .transcribing
        Chime.shared.play()
        HUD.shared.show(.transcribing)
        log(String(format: "recording stopped (%.0f ms of speech, %.1f s captured, %d KB) — transcribing",
                   duration * 1000, captured, bytes / 1024))

        // Wall-clock from the moment you press stop to the text landing.
        let stopPressed = Date()

        transcribe(fileURL: url) { [weak self] (result: TranscribeResult) in
            if case .failure = result {
                // Keep the last rejected file next to the log so it can be inspected.
                let keep = logFileURL.deletingLastPathComponent().appendingPathComponent("voice-transcriber-last-failed.m4a")
                try? FileManager.default.removeItem(at: keep)
                try? FileManager.default.moveItem(at: url, to: keep)
            }
            try? FileManager.default.removeItem(at: url)
            self?.state = .idle
            switch result {
            case .success(let raw):
                let text = applyReplacements(raw)
                // On a silent take the model tends to echo the vocabulary prompt
                // back as the "transcript" — that is not speech, don't paste it.
                guard !text.isEmpty, !isPromptEcho(text) else {
                    HUD.shared.show(.error("No speech detected"))
                    log(text.isEmpty ? "empty transcript" : "transcript was the vocabulary prompt echoed back — discarded")
                    return
                }
                let pasted = deliver(text, into: self?.targetApp)
                if asNote { NotesStore.shared.add(text, app: self?.targetApp?.localizedName) }
                let ms = Date().timeIntervalSince(stopPressed) * 1000
                let verb = (pasted ? "Pasted" : "Copied") + (asNote ? " · Noted" : "")
                HUD.shared.show(.done(String(format: "%@ ✓  %.0f ms", verb, ms)))
                log(String(format: "delivered %d chars in %.0f ms end-to-end (pasted: %@ → %@%@)",
                           text.count, ms, pasted ? "true" : "false",
                           self?.targetApp?.localizedName ?? "unknown app",
                           asNote ? ", saved as note" : ""))
            case .failure(let msg):
                HUD.shared.show(.error(msg))
                log("transcription failed: \(msg)")
            }
        }
    }

    private func teardownRecording() {
        session?.stopRunning() // synchronous: no more sample buffers after this returns
        session = nil
        // Releasing the file is what finalises the AAC container — do it under the
        // lock so a tap callback still in flight can't write into a closed file.
        fileLock.lock()
        audioFile = nil
        converter = nil
        fileLock.unlock()
        recordingURL = nil
        tickTimer?.invalidate(); tickTimer = nil
        maxTimer?.invalidate(); maxTimer = nil
        unregisterEscape()
    }

    // Esc is only swallowed globally WHILE recording.
    private func registerEscape() {
        let id = EventHotKeyID(signature: OSType(0x56545243), id: 2)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &escHotKey)
    }

    private func unregisterEscape() {
        if let hk = escHotKey { UnregisterEventHotKey(hk); escHotKey = nil }
    }
}

// MARK: - Notes window (⌥N while idle)

/// Borderless panel that can take keyboard focus without activating the app —
/// so opening it never steals the menu bar or the app you were working in.
final class NotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func keyDown(with e: NSEvent) {
        let cmdW = e.modifierFlags.contains(.command) && e.charactersIgnoringModifiers == "w"
        if e.keyCode == UInt16(kVK_Escape) || cmdW { NotesWindow.shared.close() }
        // Everything else is swallowed on purpose — there is nothing to type here.
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// One note. Hover reveals "Copy"; a click anywhere on the row copies it.
private final class NoteRowView: NSView {
    private let note: Note
    private let copyChip = NSView()
    private let copyLabel = NSTextField(labelWithString: "Copy")
    private var revertTimer: Timer?

    init(note: Note, width: CGFloat) {
        self.note = note
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10

        let meta = NSTextField(labelWithString: NoteRowView.metaText(note))
        meta.translatesAutoresizingMaskIntoConstraints = false
        meta.font = rounded(10.5, .semibold, monoDigits: true)
        meta.textColor = NSColor.white.withAlphaComponent(0.42)

        copyLabel.translatesAutoresizingMaskIntoConstraints = false
        copyLabel.font = rounded(10.5, .semibold)
        copyLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        copyChip.translatesAutoresizingMaskIntoConstraints = false
        copyChip.wantsLayer = true
        copyChip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        copyChip.layer?.cornerRadius = 6
        copyChip.alphaValue = 0
        copyChip.addSubview(copyLabel)

        let body = NSTextField(wrappingLabelWithString: note.text)
        body.translatesAutoresizingMaskIntoConstraints = false
        body.font = rounded(13, .regular)
        body.textColor = NSColor.white.withAlphaComponent(0.92)
        body.isSelectable = false
        body.preferredMaxLayoutWidth = width - 32
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(meta)
        addSubview(copyChip)
        addSubview(body)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            meta.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            meta.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            copyChip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            copyChip.centerYAnchor.constraint(equalTo: meta.centerYAnchor),
            copyLabel.leadingAnchor.constraint(equalTo: copyChip.leadingAnchor, constant: 8),
            copyLabel.trailingAnchor.constraint(equalTo: copyChip.trailingAnchor, constant: -8),
            copyLabel.topAnchor.constraint(equalTo: copyChip.topAnchor, constant: 3),
            copyLabel.bottomAnchor.constraint(equalTo: copyChip.bottomAnchor, constant: -3),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            body.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 5),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// "Today 19:57 · Claude" — relative day, then the app it went into.
    private static func metaText(_ n: Note) -> String {
        let cal = Calendar.current
        let time = DateFormatter(); time.dateFormat = "HH:mm"
        let day: String
        if cal.isDateInToday(n.createdAt) { day = "Today" }
        else if cal.isDateInYesterday(n.createdAt) { day = "Yesterday" }
        else {
            let f = DateFormatter()
            f.dateFormat = cal.isDate(n.createdAt, equalTo: Date(), toGranularity: .year) ? "EEE d MMM" : "d MMM yyyy"
            day = f.string(from: n.createdAt)
        }
        var s = "\(day) \(time.string(from: n.createdAt))"
        if let app = n.app, !app.isEmpty { s += "  ·  \(app)" }
        return s
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            layer?.backgroundColor = NSColor.white.withAlphaComponent(on ? 0.06 : 0).cgColor
            copyChip.animator().alphaValue = on ? 1 : 0
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(note.text, forType: .string)
        copyLabel.stringValue = "Copied ✓"
        copyLabel.textColor = NSColor.systemGreen
        copyChip.alphaValue = 1
        revertTimer?.invalidate()
        revertTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.copyLabel.stringValue = "Copy"
            self.copyLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        }
    }
}

final class NotesWindow {
    static let shared = NotesWindow()

    private let width: CGFloat = 440
    private var panel: NotesPanel?
    private var stack: NSStackView?
    private var scroll: NSScrollView?
    private var countLabel: NSTextField?
    private var empty: NSView?
    private var heightConstraint: NSLayoutConstraint?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? close() : open() }

    private func build() {
        let panel = NotesPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        // Same family as the HUD: near-black, one hairline, big radius. A touch
        // of behind-window blur keeps a 440pt slab from feeling like a hole.
        let root = NSVisualEffectView()
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        let tint = NSView()
        tint.translatesAutoresizingMaskIntoConstraints = false
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.74).cgColor
        root.addSubview(tint)

        // Header — title, count, and the shortcut chip the HUD also uses.
        let title = NSTextField(labelWithString: "Notes")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = rounded(17, .semibold)
        title.textColor = NSColor.white.withAlphaComponent(0.95)

        let count = NSTextField(labelWithString: "")
        count.translatesAutoresizingMaskIntoConstraints = false
        count.font = rounded(12, .medium, monoDigits: true)
        count.textColor = NSColor.white.withAlphaComponent(0.42)
        self.countLabel = count

        let chipLabel = NSTextField(labelWithString: "⌥N")
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chipLabel.font = rounded(10.5, .semibold)
        chipLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        let chip = NSView()
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        chip.layer?.cornerRadius = 6
        chip.addSubview(chipLabel)

        let rule = NSView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.wantsLayer = true
        rule.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor

        // List
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        doc.addSubview(stack)
        scroll.documentView = doc
        self.scroll = scroll
        self.stack = stack

        // Empty state
        let emptyTitle = NSTextField(labelWithString: "No notes yet")
        emptyTitle.font = rounded(13, .semibold)
        emptyTitle.textColor = NSColor.white.withAlphaComponent(0.6)
        emptyTitle.alignment = .center
        let emptyHint = NSTextField(labelWithString: "While recording, tap ⌥N to keep the dictation as a note.")
        emptyHint.font = rounded(11.5, .regular)
        emptyHint.textColor = NSColor.white.withAlphaComponent(0.38)
        emptyHint.alignment = .center
        let empty = NSStackView(views: [emptyTitle, emptyHint])
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 5
        self.empty = empty

        let footer = NSTextField(labelWithString: "Click a note to copy  ·  Esc to close")
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.font = rounded(10.5, .medium)
        footer.textColor = NSColor.white.withAlphaComponent(0.32)
        footer.alignment = .center

        [title, count, chip, rule, scroll, empty, footer].forEach(root.addSubview)
        let height = root.heightAnchor.constraint(equalToConstant: 400)
        self.heightConstraint = height
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tint.topAnchor.constraint(equalTo: root.topAnchor),
            tint.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: width),
            height,

            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            count.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            chip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            chip.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            chipLabel.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 7),
            chipLabel.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -7),
            chipLabel.topAnchor.constraint(equalTo: chip.topAnchor, constant: 3),
            chipLabel.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -3),

            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            rule.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            rule.heightAnchor.constraint(equalToConstant: 1),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -4),

            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])

        panel.contentView = root
        self.panel = panel
    }

    /// Rebuild the list from disk and size the window to fit (within limits).
    private func reload() {
        guard let stack = stack, let panel = panel, let root = panel.contentView else { return }
        NotesStore.shared.reload()
        let notes = NotesStore.shared.notes
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let rowWidth = width - 24
        for n in notes { stack.addArrangedSubview(NoteRowView(note: n, width: rowWidth)) }
        countLabel?.stringValue = notes.isEmpty ? "" : "\(notes.count)"
        empty?.isHidden = !notes.isEmpty
        scroll?.isHidden = notes.isEmpty

        // Header 63 + list padding + footer 42; grow with content up to ~70% of the screen.
        let chrome: CGFloat = 63 + 6 + 8 + 36
        let listH = notes.isEmpty ? 120 : stack.fittingSize.height + 8
        let maxH = (NSScreen.main?.visibleFrame.height ?? 800) * 0.7
        let h = min(maxH, max(200, chrome + listH))
        heightConstraint?.constant = h
        root.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: width, height: h))
        scroll?.contentView.scroll(to: .zero)
    }

    func open() {
        if panel == nil { build() }
        reload()
        guard let panel = panel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        // A little above true centre — where the eye rests, and clear of the HUD.
        panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2,
                                     y: vf.midY - size.height / 2 + vf.height * 0.06))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        log("notes window opened (\(NotesStore.shared.notes.count) notes)")
    }

    func close() {
        guard let panel = panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

// MARK: - Global hotkeys (⌥Space, ⌥N)

private var mainHotKeyRef: EventHotKeyRef?
private var noteHotKeyRef: EventHotKeyRef?
/// Holding ⌥Space makes Carbon repeat the hotkey; only the first press counts.
private var lastTogglePress = Date.distantPast

func setupHotKey() {
    var eventSpec = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed))

    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
        var hkID = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject),
                          EventParamType(typeEventHotKeyID), nil,
                          MemoryLayout<EventHotKeyID>.size, nil, &hkID)
        switch hkID.id {
        case 1:
            let now = Date()
            let repeatPress = now.timeIntervalSince(lastTogglePress) < 0.3
            lastTogglePress = now
            if !repeatPress { Controller.shared.toggle() }
        case 2: Controller.shared.cancel()
        case 3: Controller.shared.noteKey()
        default: break
        }
        return noErr
    }, 1, &eventSpec, nil, nil)

    let sig = OSType(0x56545243) // 'VTRC'
    let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: sig, id: 1),
                                     GetApplicationEventTarget(), 0, &mainHotKeyRef)
    log(status == noErr
        ? "hotkey registered: ⌥Space"
        : "hotkey registration FAILED (\(status)) — is another app using ⌥Space?")

    let noteStatus = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(optionKey), EventHotKeyID(signature: sig, id: 3),
                                         GetApplicationEventTarget(), 0, &noteHotKeyRef)
    log(noteStatus == noErr
        ? "hotkey registered: ⌥N"
        : "⌥N registration FAILED (\(noteStatus)) — is another app using ⌥N?")
}

// MARK: - Main

// MARK: - Settings window (menu bar → Settings…)

/// Borderless panel in the Notes family. An accessory app has no Edit menu, so
/// ⌘X/C/V/A/Z are routed by hand or they'd do nothing in the text fields.
final class SettingsPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command), let key = e.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: e)
        }
        let action: Selector?
        switch key {
        case "x": action = #selector(NSText.cut(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        case "z": action = mods.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        case "w": SettingsWindow.shared.close(); return true
        default: action = nil
        }
        if let action = action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: e)
    }
    override func cancelOperation(_ sender: Any?) { SettingsWindow.shared.close() }
}

private func white(_ a: CGFloat) -> NSColor { NSColor.white.withAlphaComponent(a) }

private func textLabel(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ alpha: CGFloat,
                       mono: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.translatesAutoresizingMaskIntoConstraints = false
    l.font = rounded(size, weight, monoDigits: mono)
    l.textColor = white(alpha)
    l.lineBreakMode = .byTruncatingTail
    return l
}

/// Frameless text input — the row it sits in provides the chrome.
private func plainField(_ placeholder: String, align: NSTextAlignment = .left, secure: Bool = false,
                        size: CGFloat = 13) -> NSTextField {
    let f: NSTextField = secure ? NSSecureTextField() : NSTextField()
    f.translatesAutoresizingMaskIntoConstraints = false
    f.isBordered = false
    f.drawsBackground = false
    f.focusRingType = .none
    f.font = rounded(size, .regular)
    f.textColor = white(0.92)
    f.alignment = align
    f.cell?.isScrollable = true
    f.cell?.wraps = false
    let para = NSMutableParagraphStyle()
    para.alignment = align
    f.placeholderAttributedString = NSAttributedString(
        string: placeholder, attributes: [.font: rounded(size, .regular), .foregroundColor: white(0.28),
                                          .paragraphStyle: para])
    return f
}

private func hairline() -> NSView {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    v.wantsLayer = true
    v.layer?.backgroundColor = white(0.07).cgColor
    v.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return v
}

/// Button that runs a closure: icon-only (×) or quiet text ("Change", tabs).
final class ClosureButton: NSButton {
    private let handler: () -> Void
    init(symbol: String, pointSize: CGFloat, alpha: CGFloat, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .bold))
        imagePosition = .imageOnly
        contentTintColor = white(alpha)
        setup()
    }
    init(text: String, size: CGFloat = 11.5, alpha: CGFloat = 0.55, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        setText(text, size: size, alpha: alpha)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        focusRingType = .none
        target = self
        action = #selector(fire)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    func setText(_ s: String, size: CGFloat, alpha: CGFloat) {
        attributedTitle = NSAttributedString(string: s, attributes: [.font: rounded(size, .semibold),
                                                                    .foregroundColor: white(alpha)])
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func fire() { handler() }
}

/// Monochrome capsule switch — NSSwitch only comes in the system accent blue.
final class ToggleSwitch: NSView {
    var isOn = false { didSet { needsDisplay = true } }
    var onChange: ((Bool) -> Void)?
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 18))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        (isOn ? white(0.9) : white(0.14)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        let d: CGFloat = 14
        let x = isOn ? bounds.width - d - 2 : 2
        (isOn ? NSColor.black.withAlphaComponent(0.85) : white(0.7)).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: (bounds.height - d) / 2, width: d, height: d)).fill()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        onChange?(isOn)
    }
}

/// Faint background on hover; reports hover so rows can reveal their ×.
class HoverView: NSView {
    var rest: CGFloat = 0 { didSet { layer?.backgroundColor = white(rest).cgColor } }
    var hover: CGFloat = 0.06
    var onHover: ((Bool) -> Void)?
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { set(true) }
    override func mouseExited(with event: NSEvent) { set(false) }
    private func set(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            layer?.backgroundColor = white(on ? hover : rest).cgColor
            onHover?(on)
        }
    }
}

/// Lays its subviews out left-to-right, wrapping at a fixed width (the name chips).
final class FlowView: NSView {
    private let width: CGFloat
    private let gap: CGFloat = 6
    override var isFlipped: Bool { true }
    init(width: CGFloat) {
        self.width = width
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: width, height: arrange(apply: false)) }
    override func layout() {
        super.layout()
        _ = arrange(apply: true)
    }
    private func arrange(apply: Bool) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in subviews {
            let s = v.fittingSize
            if x > 0, x + s.width > width { x = 0; y += line + gap; line = 0 }
            if apply { v.frame = NSRect(x: x, y: y, width: s.width, height: s.height) }
            x += s.width + gap
            line = max(line, s.height)
        }
        return y + line
    }
}

/// Every config.json setting, in three quiet tabs. There is no Save button:
/// each change is written straight to the file (0600, unknown keys kept) and
/// swapped into the live config, so it applies from the next take.
final class SettingsWindow: NSObject, NSTextFieldDelegate {
    static let shared = SettingsWindow()

    private let path = ("~/.config/voice-transcriber/config.json" as NSString).expandingTildeInPath
    private let width: CGFloat = 440
    private let inner: CGFloat = 396
    private let models = ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]
    private let lengths: [(Int, String)] = [(60, "1 min"), (120, "2 min"), (300, "5 min"),
                                            (600, "10 min"), (900, "15 min")]
    private let tabTitles = ["Words", "Recording"]

    private var window: SettingsPanel?
    private var tabButtons: [ClosureButton] = []
    private var page: NSView?
    private var pageHost: NSView?
    private var status: NSTextField?
    private var statusTimer: Timer?
    private var tab = 0

    // Working state, loaded from config.json on open.
    private var fixes: [(String, String)] = []
    private var names: [String] = []
    private var editingKey = false

    // Long-lived inputs, re-parented whenever a page is rebuilt.
    private let heard = plainField("Heard as")
    private let writeAs = plainField("Write as")
    private let addName = plainField("Add a name", size: 12)
    private let model = NSPopUpButton()
    private let maxLength = NSPopUpButton()
    private let language = plainField("Auto-detect", align: .right)
    private let autoPaste = ToggleSwitch()
    private let newKey = plainField("Paste a new key", align: .right, secure: true)

    override init() {
        super.init()
        for f in [heard, writeAs, addName, language, newKey] {
            f.delegate = self
        }
        heard.target = self; heard.action = #selector(fixReturn(_:))
        writeAs.target = self; writeAs.action = #selector(fixReturn(_:))
        addName.target = self; addName.action = #selector(addNames)
        heard.widthAnchor.constraint(equalToConstant: 140).isActive = true
        for p in [model, maxLength] {
            p.translatesAutoresizingMaskIntoConstraints = false
            p.isBordered = false
            p.font = rounded(12.5, .medium)
            (p.cell as? NSPopUpButtonCell)?.alignment = .right
            p.target = self
            p.action = #selector(save)
        }
        model.addItems(withTitles: models)
        for (secs, name) in lengths { maxLength.addItem(withTitle: name); maxLength.lastItem?.tag = secs }
        autoPaste.onChange = { [weak self] _ in self?.save() }
        for (f, w) in [(language, 150), (newKey, 230)] {
            f.widthAnchor.constraint(equalToConstant: CGFloat(w)).isActive = true
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func open(tab start: Int? = nil) {
        if let start = start { tab = start }
        if window == nil { build() }
        load()
        editingKey = false
        show(tab: tab, animated: false)
        if let w = window, let screen = NSScreen.main {
            let vf = screen.visibleFrame
            w.setFrameTopLeftPoint(NSPoint(x: vf.midX - width / 2, y: vf.maxY - vf.height * 0.14))
            w.alphaValue = 0
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                w.animator().alphaValue = 1
            }
        }
    }

    func close() {
        guard let w = window else { return }
        w.makeFirstResponder(nil) // ends any edit, which saves it
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            w.animator().alphaValue = 0
        }, completionHandler: { w.orderOut(nil) })
    }

    private func raw() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func load() {
        let d = raw()
        let reps = d["replacements"] as? [String: String] ?? [:]
        fixes = reps.keys.sorted { $0.lowercased() < $1.lowercased() }.map { ($0, reps[$0]!) }
        names = d["vocabulary"] as? [String] ?? []
        let m = d["model"] as? String ?? "gpt-4o-transcribe"
        if model.item(withTitle: m) == nil { model.addItem(withTitle: m) }
        model.selectItem(withTitle: m)
        let secs = (d["maxSeconds"] as? NSNumber)?.intValue ?? 300
        if maxLength.indexOfItem(withTag: secs) < 0 {
            maxLength.addItem(withTitle: "\(secs) s")
            maxLength.lastItem?.tag = secs
        }
        maxLength.selectItem(withTag: secs)
        language.stringValue = d["language"] as? String ?? ""
        autoPaste.isOn = d["autoPaste"] as? Bool ?? true
        for f in [heard, writeAs, addName, newKey] { f.stringValue = "" }
    }

    // MARK: Chrome

    private func build() {
        let w = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.appearance = NSAppearance(named: .darkAqua)

        let root = NSVisualEffectView()
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = white(0.10).cgColor
        let tint = NSView()
        tint.translatesAutoresizingMaskIntoConstraints = false
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.74).cgColor
        root.addSubview(tint)

        let title = textLabel("Settings", 17, .semibold, 0.95)

        // Segmented tabs: one soft capsule, the active tab lifted inside it.
        let tabs = NSStackView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.spacing = 2
        tabs.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        tabs.wantsLayer = true
        tabs.layer?.backgroundColor = white(0.06).cgColor
        tabs.layer?.cornerRadius = 8
        tabButtons = tabTitles.enumerated().map { i, t in
            let b = ClosureButton(text: t, size: 11.5) { [weak self] in self?.show(tab: i, animated: true) }
            b.wantsLayer = true
            b.layer?.cornerRadius = 6
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            b.widthAnchor.constraint(equalToConstant: b.intrinsicContentSize.width + 22).isActive = true
            tabs.addArrangedSubview(b)
            return b
        }

        let rule = hairline()
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        pageHost = host

        let status = textLabel("", 10.5, .medium, 0.3)
        status.alignment = .center
        self.status = status
        setStatus(nil)

        [title, tabs, rule, host, status].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tint.topAnchor.constraint(equalTo: root.topAnchor),
            tint.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: width),

            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            tabs.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            rule.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            rule.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 14),
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            status.topAnchor.constraint(equalTo: host.bottomAnchor, constant: 14),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
        w.contentView = root
        window = w
    }

    private func setStatus(_ s: String?, error: Bool = false) {
        statusTimer?.invalidate()
        guard let status = status else { return }
        if let s = s {
            status.stringValue = s
            status.textColor = error ? NSColor.systemOrange : NSColor.systemGreen.withAlphaComponent(0.9)
            if !error {
                statusTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
                    self?.setStatus(nil)
                }
            }
        } else {
            status.stringValue = "Changes save automatically  ·  Esc to close"
            status.textColor = white(0.3)
        }
    }

    private func show(tab i: Int, animated: Bool) {
        tab = i
        for (j, b) in tabButtons.enumerated() {
            b.setText(tabTitles[j], size: 11.5, alpha: j == i ? 0.95 : 0.45)
            b.layer?.backgroundColor = (j == i ? white(0.13) : .clear).cgColor
        }
        rebuild(animated: animated)
    }

    /// Swap in a freshly built page for the current tab and fit the window to it,
    /// keeping the top edge still so the tabs don't jump.
    private func rebuild(animated: Bool = true) {
        guard let host = pageHost, let w = window, let root = w.contentView else { return }
        page?.removeFromSuperview()
        let p: NSView
        switch tab {
        case 0: p = wordsPage()
        case 1: p = recordingPage()
        default: p = recordingPage()
        }
        host.addSubview(p)
        NSLayoutConstraint.activate([
            p.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            p.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            p.topAnchor.constraint(equalTo: host.topAnchor),
            p.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        page = p
        root.layoutSubtreeIfNeeded()
        let h = root.fittingSize.height
        var f = w.frame
        f.origin.y = f.maxY - h
        f.size = NSSize(width: width, height: h)
        w.setFrame(f, display: true, animate: animated && w.isVisible)
    }

    private func column(_ views: [NSView], spacing: CGFloat = 0) -> NSStackView {
        let s = NSStackView(views: views)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        for v in views { v.widthAnchor.constraint(equalToConstant: inner).isActive = true }
        return s
    }

    private func sectionHeader(_ title: String, _ hint: String) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        let t = textLabel(title.uppercased(), 10.5, .bold, 0.38)
        let h = textLabel(hint, 10.5, .medium, 0.26)
        v.addSubview(t)
        v.addSubview(h)
        NSLayoutConstraint.activate([
            v.heightAnchor.constraint(equalToConstant: 26),
            t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            t.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            h.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
            h.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    // MARK: Words

    private func wordsPage() -> NSView {
        var views: [NSView] = [sectionHeader("Spelling fixes", "heard → written")]
        for (i, fix) in fixes.enumerated() { views.append(fixRow(fix.0, fix.1, index: i)) }

        // Inline add row, styled like an empty fix row.
        let add = NSView()
        add.translatesAutoresizingMaskIntoConstraints = false
        add.wantsLayer = true
        add.layer?.cornerRadius = 8
        add.layer?.backgroundColor = white(0.05).cgColor
        let arrow = textLabel("→", 12, .medium, 0.25)
        heard.removeFromSuperview()
        writeAs.removeFromSuperview()
        [heard, arrow, writeAs].forEach(add.addSubview)
        NSLayoutConstraint.activate([
            add.heightAnchor.constraint(equalToConstant: 32),
            heard.leadingAnchor.constraint(equalTo: add.leadingAnchor, constant: 12),
            heard.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            arrow.leadingAnchor.constraint(equalTo: heard.trailingAnchor, constant: 8),
            arrow.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            writeAs.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 10),
            writeAs.trailingAnchor.constraint(equalTo: add.trailingAnchor, constant: -12),
            writeAs.centerYAnchor.constraint(equalTo: add.centerYAnchor),
        ])
        views.append(spacer(4))
        views.append(add)
        views.append(spacer(18))

        views.append(sectionHeader("Names", "helps it recognise them"))
        let flow = FlowView(width: inner)
        for (i, n) in names.enumerated() { flow.addSubview(chip(n, index: i)) }
        let adder = NSView()
        adder.wantsLayer = true
        adder.layer?.cornerRadius = 11
        adder.layer?.borderWidth = 1
        adder.layer?.borderColor = white(0.12).cgColor
        addName.removeFromSuperview()
        adder.addSubview(addName)
        NSLayoutConstraint.activate([
            adder.heightAnchor.constraint(equalToConstant: 22),
            adder.widthAnchor.constraint(equalToConstant: 110),
            addName.leadingAnchor.constraint(equalTo: adder.leadingAnchor, constant: 10),
            addName.trailingAnchor.constraint(equalTo: adder.trailingAnchor, constant: -8),
            addName.centerYAnchor.constraint(equalTo: adder.centerYAnchor),
        ])
        flow.addSubview(adder)
        views.append(spacer(2))
        views.append(flow)
        views.append(spacer(4))
        return column(views)
    }

    private func fixRow(_ from: String, _ to: String, index: Int) -> NSView {
        let row = HoverView()
        row.layer?.cornerRadius = 8
        let a = textLabel(from, 13, .regular, 0.5)
        let arrow = textLabel("→", 12, .medium, 0.25)
        let b = textLabel(to, 13, .semibold, 0.95)
        let x = ClosureButton(symbol: "xmark", pointSize: 9, alpha: 0.5) { [weak self] in
            self?.fixes.remove(at: index)
            self?.save()
            self?.rebuild()
        }
        x.alphaValue = 0
        row.onHover = { x.animator().alphaValue = $0 ? 1 : 0 }
        [a, arrow, b, x].forEach(row.addSubview)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 32),
            a.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            a.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            a.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
            arrow.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 160),
            arrow.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            b.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 10),
            b.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            b.trailingAnchor.constraint(lessThanOrEqualTo: x.leadingAnchor, constant: -8),
            x.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            x.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func chip(_ name: String, index: Int) -> NSView {
        let c = HoverView()
        c.rest = 0.08
        c.hover = 0.15
        c.layer?.cornerRadius = 11
        c.translatesAutoresizingMaskIntoConstraints = true
        let l = textLabel(name, 12, .medium, 0.85)
        let x = ClosureButton(symbol: "xmark", pointSize: 7, alpha: 0.35) { [weak self] in
            self?.names.remove(at: index)
            self?.save()
            self?.rebuild()
        }
        c.onHover = { x.contentTintColor = white($0 ? 0.8 : 0.35) }
        c.addSubview(l)
        c.addSubview(x)
        NSLayoutConstraint.activate([
            c.heightAnchor.constraint(equalToConstant: 22),
            l.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 10),
            l.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            x.leadingAnchor.constraint(equalTo: l.trailingAnchor, constant: 5),
            x.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -8),
            x.centerYAnchor.constraint(equalTo: c.centerYAnchor),
        ])
        return c
    }

    @objc private func fixReturn(_ sender: NSTextField) {
        let from = heard.stringValue.trimmingCharacters(in: .whitespaces)
        let to = writeAs.stringValue.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty else { return }
        guard !to.isEmpty else { window?.makeFirstResponder(writeAs); return }
        fixes.removeAll { $0.0.lowercased() == from.lowercased() }
        fixes.append((from, to))
        heard.stringValue = ""
        writeAs.stringValue = ""
        save()
        rebuild()
        window?.makeFirstResponder(heard)
    }

    @objc private func addNames() {
        let new = addName.stringValue.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !new.isEmpty else { return }
        for n in new where !names.contains(where: { $0.lowercased() == n.lowercased() }) { names.append(n) }
        addName.stringValue = ""
        save()
        rebuild()
        window?.makeFirstResponder(addName)
    }

    // MARK: Recording

    private func settingRow(_ title: String, sub: String? = nil, _ control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let t = textLabel(title, 13, .medium, 0.9)
        control.removeFromSuperview()
        control.translatesAutoresizingMaskIntoConstraints = false
        [t, control].forEach(row.addSubview)
        var cs = [
            row.heightAnchor.constraint(equalToConstant: sub == nil ? 44 : 52),
            t.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -2),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ]
        if let sub = sub {
            let s = textLabel(sub, 11, .regular, 0.38)
            row.addSubview(s)
            cs += [t.bottomAnchor.constraint(equalTo: row.centerYAnchor, constant: 1),
                   s.leadingAnchor.constraint(equalTo: t.leadingAnchor),
                   s.topAnchor.constraint(equalTo: row.centerYAnchor, constant: 3),
                   s.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12)]
        } else {
            cs.append(t.centerYAnchor.constraint(equalTo: row.centerYAnchor))
        }
        NSLayoutConstraint.activate(cs)
        return row
    }

    private func rows(_ rows: [NSView]) -> NSView {
        var views: [NSView] = []
        for (i, r) in rows.enumerated() {
            if i > 0 { views.append(hairline()) }
            views.append(r)
        }
        return column(views)
    }

    private func keyControl() -> NSView {
        if editingKey { return newKey }
        let key = raw()["openaiKey"] as? String ?? ""
        let masked = textLabel(key.isEmpty ? "Not set" : "••••  " + String(key.suffix(4)), 12, .medium, 0.4, mono: true)
        let change = ClosureButton(text: key.isEmpty ? "Add" : "Change") { [weak self] in
            self?.editingKey = true
            self?.rebuild()
            if let self = self { self.window?.makeFirstResponder(self.newKey) }
        }
        let s = NSStackView(views: [masked, change])
        s.spacing = 10
        return s
    }

    private func recordingPage() -> NSView {
        rows([
            settingRow("Model", model),
            settingRow("Language", sub: "Leave empty to detect it", language),
            settingRow("Paste at the cursor", sub: "Off: text is copied only", autoPaste),
            settingRow("Longest take", maxLength),
            settingRow("OpenAI key", keyControl()),
        ])
    }

    // MARK: Save

    /// Esc while typing: a field editor would otherwise show word completions.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        close()
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, ![heard, writeAs, addName].contains(f) else { return }
        if f === newKey {
            editingKey = false
            if !newKey.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { save() }
            newKey.stringValue = ""
            DispatchQueue.main.async { self.rebuild() }
            return
        }
        save()
    }

    /// Writes the current UI state to config.json and the live config.
    /// Returns false (and says why in the footer) if it couldn't.
    @discardableResult @objc func save() -> Bool {
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var d = raw()
        d["model"] = model.titleOfSelectedItem ?? "gpt-4o-transcribe"
        let lang = trim(language.stringValue)
        if lang.isEmpty { d.removeValue(forKey: "language") } else { d["language"] = lang }
        d["autoPaste"] = autoPaste.isOn
        d["maxSeconds"] = maxLength.selectedTag()
        if !trim(newKey.stringValue).isEmpty { d["openaiKey"] = trim(newKey.stringValue) }

        var reps: [String: String] = [:]
        for (from, to) in fixes { reps[from] = to }
        if reps.isEmpty { d.removeValue(forKey: "replacements") } else { d["replacements"] = reps }
        d["vocabulary"] = names


        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let fresh = try? JSONDecoder().decode(Config.self, from: data) else {
            setStatus("Couldn't save that", error: true)
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            chmod(path, 0o600)
        } catch {
            setStatus("Couldn't write the config file", error: true)
            return false
        }
        config = fresh
        log("settings saved — model \(fresh.model), \(reps.count) spelling fixes, \(names.count) names")
        setStatus("Saved ✓")
        return true
    }
}

// MARK: - Menu bar icon

/// Always-on status item naming the mic the next take will use: a mic glyph for
/// the Mac's own mic, headphones for a headset / USB / Bluetooth one, and a red
/// filled mic while recording. Click for the full device name and the notes.
final class MenuBar: NSObject, NSMenuDelegate {
    static let shared = MenuBar()
    private var item: NSStatusItem?
    private var recording = false
    private var device: AudioInput.Device?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        refresh()
        // Re-check whenever a mic is plugged in / removed or the default input changes.
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
                self?.refresh()
            }
        }
    }

    func setRecording(_ on: Bool) {
        guard on != recording else { return }
        recording = on
        refresh()
    }

    private func refresh() {
        guard let button = item?.button else { return }
        device = AudioInput.preferred()
        let symbol = recording ? "mic.fill" : (device?.isBuiltInMic ?? true) ? "mic" : "headphones"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Microphone")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = recording ? .systemRed : nil
        button.toolTip = "Voice Transcriber — \(device?.name ?? "no microphone")"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        let header = NSMenuItem(title: recording ? "Recording from" : "Recording mic", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let name = NSMenuItem(title: device?.name ?? "No microphone found", action: nil, keyEquivalent: "")
        name.image = NSImage(systemSymbolName: (device?.isBuiltInMic ?? true) ? "mic" : "headphones",
                             accessibilityDescription: nil)
        name.isEnabled = false
        menu.addItem(name)
        menu.addItem(.separator())
        let notes = NSMenuItem(title: "Notes", action: #selector(openNotes), keyEquivalent: "")
        notes.target = self
        menu.addItem(notes)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let hint = NSMenuItem(title: "⌥Space record · ⌥N note", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

    @objc private func openNotes() { NotesWindow.shared.toggle() }
    @objc private func openSettings() { SettingsWindow.shared.open() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Trigger the one-time microphone consent prompt up front.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            log("microphone access \(granted ? "granted" : "DENIED — enable in System Settings > Privacy & Security > Microphone")")
        }
        // Trigger the Accessibility prompt (needed to auto-paste into other apps).
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        log("accessibility trusted: \(trusted)\(trusted ? "" : " — enable in System Settings > Privacy & Security > Accessibility to auto-paste (clipboard-only until then)")")

        // Plugging in / unplugging a display invalidates the HUD's cached geometry.
        NotificationCenter.default.addObserver(
            HUD.shared, selector: #selector(HUD.screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        _ = Chime.shared // warm the audio engine so the first chime isn't late
        MenuBar.shared.install()
        setupHotKey()
        log("VoiceTranscriber running — model \(config.model), autoPaste \(config.autoPaste ?? true)")
    }
}


// `VoiceTranscriber --preview-hud [note]` shows the recording pill for the mic a
// take would use right now, for 4 s, without touching the mic or the hotkeys.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--preview-hud" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let note = CommandLine.arguments.count >= 3 && CommandLine.arguments[2] == "note"
    let dev = AudioInput.preferred()
    let name = dev.flatMap { AVCaptureDevice(uniqueID: $0.uid)?.localizedName } ?? dev?.name ?? "system default"
    print("mic: \(name)")
    HUD.shared.setMic(name)
    HUD.shared.show(.recording(elapsed: 3.21, level: 0.5, note: note))
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
    app.run()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
