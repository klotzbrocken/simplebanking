import AppKit
import Foundation

@MainActor
final class MediumClippy: NSObject {
    private struct Frame {
        let x: Int
        let y: Int
        let duration: TimeInterval
    }

    private struct CatalogAnimation: Decodable {
        let name: String
        let frames: [CatalogFrame]

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case frames = "Frames"
        }
    }

    private struct CatalogFrame: Decodable {
        let duration: Double
        let offsets: CatalogOffsets?

        enum CodingKeys: String, CodingKey {
            case duration = "Duration"
            case offsets = "ImagesOffsets"
        }
    }

    private struct CatalogOffsets: Decodable {
        let column: Int
        let row: Int

        enum CodingKeys: String, CodingKey {
            case column = "Column"
            case row = "Row"
        }
    }

    private enum ScriptStep: Int, CaseIterable {
        case greeting
        case thinking
        case surprised
        case processing
        case techy
        case idle
    }

    private let frameWidth = 124
    private let frameHeight = 93

    private weak var hostView: NSView?
    private var overlayView: NSView?
    private var speechBubbleView: NSView?
    private var speechLabel: NSTextField?
    private var imageView: NSImageView?
    private var spriteSheet: NSImage?
    private var animationTask: Task<Void, Never>?
    private var idlePauseTask: Task<Void, Never>?
    private var textToIdleTask: Task<Void, Never>?

    // MARK: - Autonomous Mode
    private static let autonomousKey = "clippy.autonomous"
    private var autonomousTask: Task<Void, Never>?
    private weak var autonomousHost: NSView?

    var isAutonomousMode: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autonomousKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autonomousKey) }
    }

    /// Toggle autonomous mode. Clippy will appear randomly every 60–180 min when enabled.
    func setAutonomousMode(_ enabled: Bool, on host: NSView?) {
        isAutonomousMode = enabled
        if enabled {
            autonomousHost = host ?? autonomousHost
            scheduleNextAutonomousAppearance()
        } else {
            autonomousTask?.cancel()
            autonomousTask = nil
        }
    }

    /// Resume autonomous timer after re-opening the panel (host view may have changed).
    func resumeAutonomousModeIfEnabled(on host: NSView?) {
        guard isAutonomousMode else { return }
        autonomousHost = host ?? autonomousHost
        guard autonomousTask == nil else { return }
        scheduleNextAutonomousAppearance()
    }

    /// Show Clippy with a feedback message (e.g. after toggling autonomous mode).
    func showFeedback(autonomousEnabled: Bool, on host: NSView?) {
        guard !isClosing else { return }
        let text = autonomousEnabled
            ? "📎 Autonomer Modus an! Ich erscheine jetzt aus eigenem Antrieb."
            : "Autonomer Modus aus. Manuell wie immer."
        if !isVisible {
            let targetHost = host ?? hostView
            guard spriteSheet != nil, let targetHost else { return }
            hostView = targetHost
            if overlayView == nil || overlayView?.superview !== targetHost {
                installOverlay(on: targetHost)
            }
            isVisible = true
            isClosing = false
        }
        cancelDeferredTasks()
        playFrameSequence(frames(named: "Wave", fallback: waveFrames), loop: false) { [weak self] in
            self?.showSpeech(text)
            self?.scheduleTransitionToIdleAfterSpeech()
        }
    }

    private func scheduleNextAutonomousAppearance() {
        guard isAutonomousMode else { return }
        autonomousTask?.cancel()
        let minutes = Double.random(in: 60...180)
        let nanos = UInt64(minutes * 60.0 * 1_000_000_000.0)
        autonomousTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanos)
            } catch { return }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isAutonomousMode else { return }
                let host = self.autonomousHost ?? self.hostView
                if !self.isVisible {
                    self.show(on: host)
                }
                self.autonomousTask = nil
                self.scheduleNextAutonomousAppearance()
            }
        }
    }

    private var isVisible = false
    private var isClosing = false
    private var scriptIndex = 0
    private var activeFrames: [Frame] = []
    private var activeFrameIndex = 0
    private var activeLoop = false
    private var animationGeneration = 0
    private var onAnimationFinished: (() -> Void)?
    private var animationCatalog: [String: [Frame]] = [:]
    private let sequenceSteps: [ScriptStep] = [.greeting, .thinking, .surprised, .processing, .techy]

    private let showFrames: [Frame] = [
        Frame(x: 0, y: 0, duration: 0.08),
        Frame(x: 124, y: 0, duration: 0.08),
        Frame(x: 248, y: 0, duration: 0.08),
        Frame(x: 372, y: 0, duration: 0.08),
        Frame(x: 496, y: 0, duration: 0.08),
    ]

    private let waveFrames: [Frame] = [
        Frame(x: 0, y: 93, duration: 0.08),
        Frame(x: 124, y: 93, duration: 0.08),
        Frame(x: 248, y: 93, duration: 0.08),
        Frame(x: 372, y: 93, duration: 0.08),
        Frame(x: 496, y: 93, duration: 0.08),
        Frame(x: 620, y: 93, duration: 0.08),
        Frame(x: 744, y: 93, duration: 0.08),
        Frame(x: 868, y: 93, duration: 0.08),
        Frame(x: 0, y: 186, duration: 0.08),
        Frame(x: 124, y: 186, duration: 0.08),
        Frame(x: 248, y: 186, duration: 0.08),
        Frame(x: 372, y: 186, duration: 0.08),
    ]

    private let thinkingFrames: [Frame] = [
        Frame(x: 744, y: 186, duration: 0.12),
        Frame(x: 868, y: 186, duration: 0.12),
        Frame(x: 0, y: 279, duration: 0.12),
        Frame(x: 124, y: 279, duration: 0.12),
        Frame(x: 248, y: 279, duration: 0.12),
        Frame(x: 372, y: 279, duration: 0.12),
        Frame(x: 496, y: 279, duration: 0.12),
        Frame(x: 620, y: 279, duration: 0.12),
        Frame(x: 744, y: 279, duration: 0.12),
        Frame(x: 868, y: 279, duration: 0.12),
    ]

    private let surprisedFrames: [Frame] = [
        Frame(x: 0, y: 372, duration: 0.10),
        Frame(x: 124, y: 372, duration: 0.10),
        Frame(x: 248, y: 372, duration: 0.10),
        Frame(x: 372, y: 372, duration: 0.10),
        Frame(x: 496, y: 372, duration: 0.15),
        Frame(x: 620, y: 372, duration: 0.10),
        Frame(x: 744, y: 372, duration: 0.10),
        Frame(x: 868, y: 372, duration: 0.10),
    ]

    private let processingFrames: [Frame] = [
        Frame(x: 0, y: 465, duration: 0.12),
        Frame(x: 124, y: 465, duration: 0.12),
        Frame(x: 248, y: 465, duration: 0.12),
        Frame(x: 372, y: 465, duration: 0.12),
        Frame(x: 496, y: 465, duration: 0.12),
        Frame(x: 620, y: 465, duration: 0.12),
        Frame(x: 744, y: 465, duration: 0.12),
        Frame(x: 868, y: 465, duration: 0.12),
        Frame(x: 0, y: 558, duration: 0.12),
        Frame(x: 124, y: 558, duration: 0.12),
    ]

    private let techyFrames: [Frame] = [
        Frame(x: 248, y: 558, duration: 0.10),
        Frame(x: 372, y: 558, duration: 0.10),
        Frame(x: 496, y: 558, duration: 0.10),
        Frame(x: 620, y: 558, duration: 0.10),
        Frame(x: 744, y: 558, duration: 0.10),
        Frame(x: 868, y: 558, duration: 0.10),
        Frame(x: 0, y: 651, duration: 0.10),
        Frame(x: 124, y: 651, duration: 0.10),
        Frame(x: 248, y: 651, duration: 0.10),
        Frame(x: 372, y: 651, duration: 0.10),
        Frame(x: 496, y: 651, duration: 0.10),
        Frame(x: 620, y: 651, duration: 0.10),
    ]

    private let restPoseFrames: [Frame] = [
        Frame(x: 496, y: 186, duration: 0.30),
    ]
    private let idleEyeBrowRaiseFrames: [Frame] = [
        Frame(x: 620, y: 186, duration: 0.15),
        Frame(x: 744, y: 186, duration: 0.15),
        Frame(x: 868, y: 186, duration: 0.15),
    ]
    private let idleFingerTapFrames: [Frame] = [
        Frame(x: 0, y: 279, duration: 0.12),
        Frame(x: 124, y: 279, duration: 0.12),
        Frame(x: 248, y: 279, duration: 0.12),
    ]
    private let idleHeadScratchFrames: [Frame] = [
        Frame(x: 372, y: 279, duration: 0.15),
        Frame(x: 496, y: 279, duration: 0.15),
        Frame(x: 620, y: 279, duration: 0.15),
    ]
    private let idleSideToSideFrames: [Frame] = [
        Frame(x: 744, y: 279, duration: 0.12),
        Frame(x: 868, y: 279, duration: 0.12),
        Frame(x: 744, y: 279, duration: 0.12),
    ]

    private let goodByeFrames: [Frame] = [
        Frame(x: 744, y: 651, duration: 0.10),
        Frame(x: 868, y: 651, duration: 0.10),
        Frame(x: 0, y: 744, duration: 0.10),
        Frame(x: 124, y: 744, duration: 0.10),
        Frame(x: 248, y: 744, duration: 0.10),
        Frame(x: 372, y: 744, duration: 0.10),
        Frame(x: 496, y: 744, duration: 0.10),
    ]

    override init() {
        super.init()
        loadSpriteSheet()
        loadAnimationCatalog()
    }

    deinit {
        animationTask?.cancel()
        idlePauseTask?.cancel()
        textToIdleTask?.cancel()
        autonomousTask?.cancel()
    }

    func toggle(on host: NSView?) {
        if isVisible {
            hide()
        } else {
            show(on: host)
        }
    }

    func hide() {
        guard overlayView != nil else {
            cleanupOverlay()
            return
        }
        guard !isClosing else { return }
        isClosing = true
        cancelDeferredTasks()
        showSpeech(nil)
        playFrameSequence(frames(named: "GoodBye", fallback: goodByeFrames), loop: false) { [weak self] in
            self?.cleanupOverlay()
        }
    }

    @objc func cycleAnimation() {
        guard isVisible, !isClosing else { return }
        scriptIndex = (scriptIndex + 1) % sequenceSteps.count
        playScript(sequenceSteps[scriptIndex])
    }

    private func show(on host: NSView?) {
        guard spriteSheet != nil else {
            AppLogger.log("Clippy sprite sheet missing (Clippy.png)", category: "Clippy", level: "WARN")
            return
        }

        guard let host else { return }
        hostView = host

        if overlayView == nil || overlayView?.superview !== host {
            installOverlay(on: host)
        }

        isVisible = true
        isClosing = false
        cancelDeferredTasks()
        scriptIndex = Int.random(in: 0 ..< sequenceSteps.count)
        playScript(sequenceSteps[scriptIndex])
    }

    private func installOverlay(on host: NSView) {
        overlayView?.removeFromSuperview()

        let overlay = NSView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = false

        let bubble = SpeechBubbleView(frame: NSRect(x: 6, y: 56, width: 228, height: 90))
        bubble.wantsLayer = false
        bubble.isHidden = true
        let label = NSTextField(wrappingLabelWithString: "")
        label.frame = bubble.bounds.insetBy(dx: 12, dy: 16)
        label.autoresizingMask = [.width, .height]
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byWordWrapping
        label.textColor = .labelColor
        bubble.addSubview(label)
        speechLabel = label
        speechBubbleView = bubble

        // Transparent Clippy figure without frame.
        let clippyTapArea = NSView(frame: NSRect(x: 208, y: 10, width: 124, height: 93))
        clippyTapArea.wantsLayer = false

        let image = NSImageView(frame: clippyTapArea.bounds)
        image.autoresizingMask = [.width, .height]
        image.imageScaling = .scaleNone
        clippyTapArea.addSubview(image)
        imageView = image

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(onClippyClicked(_:)))
        clickGesture.numberOfClicksRequired = 1
        clickGesture.buttonMask = 0x1
        clippyTapArea.addGestureRecognizer(clickGesture)

        overlay.addSubview(bubble)
        overlay.addSubview(clippyTapArea)
        host.addSubview(overlay)

        NSLayoutConstraint.activate([
            overlay.widthAnchor.constraint(equalToConstant: 336),
            overlay.heightAnchor.constraint(equalToConstant: 156),
            overlay.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10),
            overlay.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -74),
        ])

        overlayView = overlay
    }

    @objc private func onClippyClicked(_ sender: NSClickGestureRecognizer) {
        guard sender.state == .ended else { return }
        cycleAnimation()
    }

    private func showSpeech(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            speechBubbleView?.isHidden = true
            speechLabel?.stringValue = ""
            return
        }
        speechLabel?.stringValue = trimmed
        speechBubbleView?.isHidden = false
    }

    private func playScript(_ step: ScriptStep) {
        guard isVisible, !isClosing else { return }
        cancelDeferredTasks()

        switch step {
        case .greeting:
            showSpeech(ClippyQuotes.randomGreeting())
            playFrameSequence(frames(named: "Show", fallback: showFrames), loop: false) { [weak self] in
                guard let self else { return }
                self.playFrameSequence(self.frames(named: "Wave", fallback: self.waveFrames), loop: false) { [weak self] in
                    self?.scheduleTransitionToIdleAfterSpeech()
                }
            }
        case .thinking:
            playFrameSequence(frames(named: "Thinking", fallback: thinkingFrames), loop: false) { [weak self] in
                self?.showSpeech(ClippyQuotes.randomSavingTip())
                self?.scheduleTransitionToIdleAfterSpeech()
            }
        case .surprised:
            playFrameSequence(frames(named: "Alert", fallback: surprisedFrames), loop: false) { [weak self] in
                self?.showSpeech(ClippyQuotes.randomTransaction())
                self?.scheduleTransitionToIdleAfterSpeech()
            }
        case .processing:
            playFrameSequence(frames(named: "Processing", fallback: processingFrames), loop: false) { [weak self] in
                self?.showSpeech(ClippyQuotes.randomFact())
                self?.scheduleTransitionToIdleAfterSpeech()
            }
        case .techy:
            playFrameSequence(frames(named: "GetTechy", fallback: techyFrames), loop: false) { [weak self] in
                self?.showSpeech(ClippyQuotes.randomMeta())
                self?.scheduleTransitionToIdleAfterSpeech()
            }
        case .idle:
            startIdleLoop()
        }
    }

    private func scheduleTransitionToIdleAfterSpeech() {
        guard isVisible, !isClosing else { return }
        showRestPose()
        textToIdleTask?.cancel()
        let generation = animationGeneration
        let waitNanos = UInt64(Double.random(in: 5.0 ... 7.0) * 1_000_000_000)
        textToIdleTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: waitNanos)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard self.animationGeneration == generation else { return }
                self.transitionToIdle()
            }
        }
    }

    private func showRestPose() {
        guard let frame = frames(named: "RestPose", fallback: restPoseFrames).first else { return }
        displayFrame(x: frame.x, y: frame.y)
    }

    private func transitionToIdle() {
        guard isVisible, !isClosing else { return }
        textToIdleTask?.cancel()
        textToIdleTask = nil
        showSpeech(nil)
        startIdleLoop()
    }

    private func startIdleLoop() {
        guard isVisible, !isClosing else { return }
        playFrameSequence(frames(named: "RestPose", fallback: restPoseFrames), loop: false) { [weak self] in
            self?.scheduleNextIdleVariation()
        }
    }

    private func scheduleNextIdleVariation() {
        guard isVisible, !isClosing else { return }
        let generation = animationGeneration
        let pauseNanos = UInt64(Double.random(in: 2.0 ... 5.0) * 1_000_000_000)
        idlePauseTask?.cancel()
        idlePauseTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: pauseNanos)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                guard self.animationGeneration == generation else { return }
                self.playRandomIdleVariation()
            }
        }
    }

    private func playRandomIdleVariation() {
        guard isVisible, !isClosing else { return }
        let variations = [
            frames(named: "Idle1_1", fallback: idleFingerTapFrames),
            frames(named: "IdleAtom", fallback: idleHeadScratchFrames),
            frames(named: "IdleEyeBrowRaise", fallback: idleEyeBrowRaiseFrames),
            frames(named: "IdleFingerTap", fallback: idleFingerTapFrames),
            frames(named: "IdleHeadScratch", fallback: idleHeadScratchFrames),
            frames(named: "IdleRopePile", fallback: idleSideToSideFrames),
            frames(named: "IdleSideToSide", fallback: idleSideToSideFrames),
            frames(named: "IdleSnooze", fallback: idleEyeBrowRaiseFrames),
        ]
        let selected = variations.randomElement() ?? frames(named: "IdleEyeBrowRaise", fallback: idleEyeBrowRaiseFrames)
        playFrameSequence(selected, loop: false) { [weak self] in
            self?.startIdleLoop()
        }
    }

    private func cancelDeferredTasks() {
        idlePauseTask?.cancel()
        idlePauseTask = nil
        textToIdleTask?.cancel()
        textToIdleTask = nil
    }

    private func playFrameSequence(_ frames: [Frame], loop: Bool, completion: (() -> Void)? = nil) {
        animationTask?.cancel()
        guard !frames.isEmpty else {
            completion?()
            return
        }

        animationGeneration += 1
        let generation = animationGeneration
        activeFrames = frames
        activeFrameIndex = 0
        activeLoop = loop
        onAnimationFinished = completion
        renderFrameAndSchedule(generation: generation)
    }

    private func renderFrameAndSchedule(generation: Int) {
        guard generation == animationGeneration else { return }
        guard overlayView != nil else { return }
        guard !activeFrames.isEmpty else { return }

        if activeFrameIndex >= activeFrames.count {
            if activeLoop {
                activeFrameIndex = 0
            } else {
                let finished = onAnimationFinished
                onAnimationFinished = nil
                finished?()
                return
            }
        }

        let frame = activeFrames[activeFrameIndex]
        activeFrameIndex += 1
        displayFrame(x: frame.x, y: frame.y)

        let delayNanos = UInt64(max(frame.duration, 0.02) * 1_000_000_000)
        animationTask?.cancel()
        animationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanos)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.renderFrameAndSchedule(generation: generation)
            }
        }
    }

    private func cleanupOverlay() {
        animationTask?.cancel()
        animationTask = nil
        cancelDeferredTasks()
        animationGeneration += 1
        onAnimationFinished = nil

        activeFrames = []
        activeFrameIndex = 0
        activeLoop = false
        isVisible = false
        isClosing = false

        overlayView?.removeFromSuperview()
        overlayView = nil
        speechBubbleView = nil
        speechLabel = nil
        imageView = nil
    }

    private func loadSpriteSheet() {
        if let path = Bundle.main.path(forResource: "Clippy", ofType: "png"),
           let image = NSImage(contentsOfFile: path) {
            spriteSheet = image
            return
        }

        spriteSheet = nil
    }

    private func loadAnimationCatalog() {
        let decoder = JSONDecoder()

        func decodeCatalog(at path: String) -> [CatalogAnimation]? {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return try? decoder.decode([CatalogAnimation].self, from: data)
        }

        var animations: [CatalogAnimation] = []
        if let bundledPath = Bundle.main.path(forResource: "animations", ofType: "json"),
           let decoded = decodeCatalog(at: bundledPath) {
            animations = decoded
        }

        guard !animations.isEmpty else {
            AppLogger.log("animations.json missing or unreadable; using hardcoded Clippy frames", category: "Clippy", level: "WARN")
            return
        }

        var mapped: [String: [Frame]] = [:]
        mapped.reserveCapacity(animations.count)
        for entry in animations {
            var currentColumn = 0
            var currentRow = 0
            let frames: [Frame] = entry.frames.map { frame in
                if let offsets = frame.offsets {
                    currentColumn = offsets.column
                    currentRow = offsets.row
                }
                let duration = max(0.02, frame.duration / 1000.0)
                let x = currentColumn * frameWidth
                let y = currentRow * frameHeight
                return Frame(x: x, y: y, duration: duration)
            }
            mapped[entry.name] = frames
        }
        animationCatalog = mapped
        AppLogger.log("Loaded Clippy animation catalog entries: \(animationCatalog.count)", category: "Clippy")
    }

    private func frames(named name: String, fallback: [Frame]) -> [Frame] {
        if let frames = animationCatalog[name], !frames.isEmpty {
            return frames
        }
        return fallback
    }

    private func displayFrame(x: Int, y: Int) {
        guard let sheet = spriteSheet,
              let target = imageView,
              let cgImage = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        let sheetWidth = cgImage.width
        let sheetHeight = cgImage.height
        let flippedY = sheetHeight - y - frameHeight
        guard x >= 0,
              flippedY >= 0,
              x + frameWidth <= sheetWidth,
              flippedY + frameHeight <= sheetHeight
        else { return }

        let rect = CGRect(x: x, y: flippedY, width: frameWidth, height: frameHeight)
        guard let cropped = cgImage.cropping(to: rect) else { return }
        target.image = NSImage(cgImage: cropped, size: NSSize(width: frameWidth, height: frameHeight))
    }
}

private final class SpeechBubbleView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bubbleRect = NSRect(x: 0, y: 10, width: bounds.width - 2, height: bounds.height - 14)
        let rounded = NSBezierPath(roundedRect: bubbleRect, xRadius: 11, yRadius: 11)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        rounded.fill()

        NSColor.black.withAlphaComponent(0.24).setStroke()
        rounded.lineWidth = 1
        rounded.stroke()

        let tail = NSBezierPath()
        let tailBaseX = bubbleRect.maxX - 34
        let tailBaseY = bubbleRect.minY
        tail.move(to: NSPoint(x: tailBaseX, y: tailBaseY))
        tail.line(to: NSPoint(x: tailBaseX + 16, y: tailBaseY))
        tail.line(to: NSPoint(x: tailBaseX + 9, y: 2))
        tail.close()
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        tail.fill()
        NSColor.black.withAlphaComponent(0.24).setStroke()
        tail.lineWidth = 1
        tail.stroke()
    }
}
