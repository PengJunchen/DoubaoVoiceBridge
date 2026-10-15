import AppKit
import ApplicationServices

enum ShortcutRecorderMonitorHandler {
    enum FunctionKeyTransition: Equatable {
        case waitingForRelease
        case accepted
        case rejectedCombination
        case ignored
    }

    struct FunctionKeyState {
        private(set) var isDown = false
        private(set) var hasOtherModifier = false

        mutating func transition(isDown nextIsDown: Bool, hasOtherModifiers: Bool) -> FunctionKeyTransition {
            if nextIsDown {
                isDown = true
                hasOtherModifier = hasOtherModifier || hasOtherModifiers
                return .waitingForRelease
            }
            guard isDown else { return .ignored }
            isDown = false
            let result: FunctionKeyTransition = hasOtherModifier ? .rejectedCombination : .accepted
            hasOtherModifier = false
            return result
        }

        mutating func noteOtherModifierOrKey() {
            if isDown { hasOtherModifier = true }
        }

        mutating func reset() {
            isDown = false
            hasOtherModifier = false
        }
    }

    static func isPhysicalFnTransition(_ event: NSEvent) -> Bool {
        event.type == .flagsChanged && event.keyCode == 63
    }

    static func make(
        windowIsKey: @escaping () -> Bool,
        stop: @escaping () -> Void,
        consume: @escaping (NSEvent) -> NSEvent?
    ) -> (NSEvent) -> NSEvent? {
        { event in
            guard windowIsKey() else {
                stop()
                return event
            }
            return consume(event)
        }
    }
}

enum ShortcutSaveError: Error {
    case message(String)

    var localizedDescription: String {
        switch self {
        case .message(let value): return value
        }
    }
}

final class ShortcutSettingsWindowController: NSWindowController, NSWindowDelegate {
    var onSave: ((DoubaoShortcutConfiguration, DoubaoShortcutMode?, KeyboardShortcut?, BridgeShortcutConfiguration) -> Result<Void, ShortcutSaveError>)?
    var onOpenPermissions: (() -> Void)?
    var onOpenLocalTest: (() -> Void)?

    private let automaticConfiguration: DoubaoShortcutConfiguration?
    private let confirmedConfiguration: DoubaoShortcutConfiguration?
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let doubaoModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bridgePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let doubaoRecordButton = NSButton(title: "录制豆包按键…", target: nil, action: nil)
    private let bridgeRecordButton = NSButton(title: "录制远控触发键…", target: nil, action: nil)
    private let automaticSummary = NSTextField(wrappingLabelWithString: "")
    private let permissionsSummary = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "保存并启用", target: nil, action: nil)
    private var initialManualMode: DoubaoShortcutMode?
    private var initialBridgeKind: BridgeShortcutKind
    private var selectedDoubaoShortcut: KeyboardShortcut
    private var selectedBridgeShortcut: KeyboardShortcut?
    private var recordingTarget: RecordingTarget?
    private var localEventMonitor: Any?
    private var recordingModifierKeyCodes: Set<UInt16> = []
    private var recordingUsedMultipleModifiers = false
    private var recordingFunctionKeyState = ShortcutRecorderMonitorHandler.FunctionKeyState()
    private var recorderKeyUpsToSwallow: Set<UInt16> = []

    private enum RecordingTarget: Equatable {
        case doubao
        case bridge
    }

    init(
        automaticConfiguration: DoubaoShortcutConfiguration?,
        confirmedConfiguration: DoubaoShortcutConfiguration?,
        manualConfiguration: DoubaoShortcutConfiguration?,
        bridgeConfiguration: BridgeShortcutConfiguration?
    ) {
        self.automaticConfiguration = automaticConfiguration
        self.confirmedConfiguration = confirmedConfiguration
        self.initialManualMode = manualConfiguration?.mode
        self.initialBridgeKind = bridgeConfiguration?.kind ?? .followDoubao
        self.selectedDoubaoShortcut = manualConfiguration?.keyboardShortcut ??
            confirmedConfiguration?.keyboardShortcut ?? automaticConfiguration?.keyboardShortcut ?? .fn
        self.selectedBridgeShortcut = bridgeConfiguration?.shortcut

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "远控听写设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface(in: window)
        refreshFields()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
    }

    func present() {
        guard let window else { return }
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func buildInterface(in window: NSWindow) {
        guard let contentView = window.contentView else { return }

        sourcePopup.addItem(withTitle: automaticConfiguration == nil ? "自动读取（暂不可用）" : "自动读取豆包设置")
        sourcePopup.addItem(withTitle: confirmedConfiguration == nil ? "上次确认（暂不可用）" : "使用上次确认的设置")
        sourcePopup.addItem(withTitle: "手动选择受支持按键")
        sourcePopup.target = self
        sourcePopup.action = #selector(selectionChanged)
        let initialSourceIndex = initialManualMode != nil
            ? 2
            : (automaticConfiguration?.mode.isSupported == true ? 0 : (confirmedConfiguration?.mode.isSupported == true ? 1 : 2))
        sourcePopup.selectItem(at: initialSourceIndex)
        sourcePopup.item(at: 0)?.isEnabled = automaticConfiguration?.mode.isSupported == true
        sourcePopup.item(at: 1)?.isEnabled = confirmedConfiguration?.mode.isSupported == true
        if let confirmedConfiguration {
            let confirmedKey = confirmedConfiguration.keyboardShortcut.displayName
            sourcePopup.item(at: 1)?.title = "上次确认：\(confirmedKey)"
        }

        doubaoModePopup.addItem(withTitle: "长按触发，松开豆包按键结束")
        doubaoModePopup.addItem(withTitle: "单击启动，任意键结束")
        doubaoModePopup.target = self
        doubaoModePopup.action = #selector(selectionChanged)
        let initialMode = initialManualMode ?? confirmedConfiguration?.mode ?? automaticConfiguration?.mode ?? .fnToggle
        doubaoModePopup.selectItem(at: initialMode == .leftControlHold ? 0 : 1)
        doubaoRecordButton.target = self
        doubaoRecordButton.action = #selector(recordDoubaoShortcut)
        bridgeRecordButton.target = self
        bridgeRecordButton.action = #selector(recordBridgeShortcut)

        bridgePopup.addItem(withTitle: BridgeShortcutKind.followDoubao.title)
        bridgePopup.addItem(withTitle: BridgeShortcutKind.leftControlHold.title)
        bridgePopup.addItem(withTitle: BridgeShortcutKind.customHold.title)
        bridgePopup.target = self
        bridgePopup.action = #selector(selectionChanged)
        bridgePopup.selectItem(at: initialBridgeKind == .leftControlHold ? 1 : (initialBridgeKind == .customHold ? 2 : 0))

        automaticSummary.maximumNumberOfLines = 3
        automaticSummary.textColor = .secondaryLabelColor
        permissionsSummary.maximumNumberOfLines = 2
        permissionsSummary.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 3
        messageLabel.textColor = .secondaryLabelColor
        saveButton.target = self
        saveButton.action = #selector(saveConfiguration)
        saveButton.keyEquivalent = "\r"

        let title = NSTextField(labelWithString: "设置豆包语音键与远控触发键")
        title.font = .boldSystemFont(ofSize: 20)
        let heading = NSStackView()
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 12
        if let icon = NSImage(named: NSImage.Name("AppIcon")) {
            let iconView = NSImageView(image: icon)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.widthAnchor.constraint(equalToConstant: 44).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: 44).isActive = true
            heading.addArrangedSubview(iconView)
        }
        heading.addArrangedSubview(title)
        let intro = NSTextField(wrappingLabelWithString: "先确认豆包使用的按键和开始方式，再独立选择触发远控听写的按键。手动选择只保存本应用配置，不会修改豆包设置。")
        intro.textColor = .secondaryLabelColor
        intro.maximumNumberOfLines = 3

        let sourceLabel = makeSectionLabel("豆包语音按键")
        let modeLabel = makeSectionLabel("豆包语音交互方式")
        let bridgeLabel = makeSectionLabel("远控听写触发键")
        let bridgeInstruction = NSTextField(wrappingLabelWithString: "自定义远控触发键按住开始、松开结束；选择“跟随豆包”时沿用豆包自己的开始方式。")
        bridgeInstruction.textColor = .secondaryLabelColor
        bridgeInstruction.maximumNumberOfLines = 2
        let permissionsLabel = makeSectionLabel("所需权限")
        let permissionsButton = NSButton(title: "打开隐私与安全性设置…", target: self, action: #selector(openPermissions))
        let localTestButton = NSButton(title: "打开 TextEdit 进行本机识别测试…", target: self, action: #selector(openLocalTest))

        let stack = NSStackView(views: [
            heading,
            intro,
            sourceLabel,
            sourcePopup,
            automaticSummary,
            modeLabel,
            doubaoRecordButton,
            doubaoModePopup,
            bridgeLabel,
            bridgePopup,
            bridgeRecordButton,
            bridgeInstruction,
            localTestButton,
            permissionsLabel,
            permissionsSummary,
            permissionsButton,
            messageLabel,
            saveButton
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .gravityAreas
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)
        let documentView = FlippedDocumentView(frame: .zero)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        documentView.addSubview(stack)

        for control in [sourcePopup, doubaoModePopup, bridgePopup] {
            control.widthAnchor.constraint(equalToConstant: 540).isActive = true
        }
        for field in [intro, automaticSummary, bridgeInstruction, permissionsSummary, messageLabel] {
            field.widthAnchor.constraint(equalToConstant: 540).isActive = true
        }
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -20)
        ])
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: 13)
        return field
    }

    @objc private func selectionChanged() {
        refreshFields()
    }

    private func refreshFields() {
        let manual = sourcePopup.indexOfSelectedItem == 2
        doubaoModePopup.isEnabled = manual
        doubaoRecordButton.isEnabled = manual
        bridgeRecordButton.isEnabled = bridgePopup.indexOfSelectedItem == 2
        if manual {
            automaticSummary.stringValue = "录制豆包当前使用的单键或组合键，并选择长按松开结束，或单击启动后任意键结束。本工具只模拟该按键，不修改豆包设置。"
        } else {
            switch sourcePopup.indexOfSelectedItem {
            case 0:
                if let automaticConfiguration {
                    automaticSummary.stringValue = "\(automaticConfiguration.instruction)\n\(automaticConfiguration.sourceAndTime)"
                } else {
                    automaticSummary.stringValue = "当前没有可确认的自动读取结果；请选择手动配置。"
                }
            case 1:
                if let confirmedConfiguration {
                    automaticSummary.stringValue = "\(confirmedConfiguration.instruction)\n\(confirmedConfiguration.sourceAndTime)"
                } else {
                    automaticSummary.stringValue = "当前没有上次确认的按键；请选择手动配置。"
                }
            default:
                automaticSummary.stringValue = "当前没有可确认的自动读取结果；请选择手动配置。"
            }
        }

        let accessibilityGranted = AXIsProcessTrusted()
        let inputGranted = CGPreflightListenEventAccess()
        permissionsSummary.stringValue = "辅助功能：\(accessibilityGranted ? "已授权" : "未授权")；输入监控：\(inputGranted ? "已授权" : "未授权")。未授权时不会启用快捷键监听。"
        messageLabel.stringValue = "本机测试入口会打开 TextEdit；请在其中新建空白文稿，用豆包自己的按键验证真实识别。远程粘贴仍需另行在 UU 远控中验证。"
        updateSaveButtonState()
        updateRecorderTitles()
    }

    private func selectedDoubaoMode() -> (DoubaoShortcutConfiguration, DoubaoShortcutMode?)? {
        if sourcePopup.indexOfSelectedItem == 0 {
            guard let automaticConfiguration, automaticConfiguration.mode.isSupported else { return nil }
            return (automaticConfiguration, automaticConfiguration.shortcut == nil ? nil : automaticConfiguration.mode)
        }
        if sourcePopup.indexOfSelectedItem == 1 {
            guard let confirmedConfiguration, confirmedConfiguration.mode.isSupported else { return nil }
            return (confirmedConfiguration, confirmedConfiguration.shortcut == nil ? nil : confirmedConfiguration.mode)
        }
        let mode: DoubaoShortcutMode = doubaoModePopup.indexOfSelectedItem == 0 ? .leftControlHold : .fnToggle
        return (.manual(mode, shortcut: selectedDoubaoShortcut), mode)
    }

    private func selectedBridge() -> BridgeShortcutConfiguration {
        switch bridgePopup.indexOfSelectedItem {
        case 1: return .leftControlHold
        case 2: return BridgeShortcutConfiguration(kind: .customHold, shortcut: selectedBridgeShortcut)
        default: return .followDoubao
        }
    }

    private func updateSaveButtonState() {
        guard let (doubao, _) = selectedDoubaoMode() else {
            saveButton.isEnabled = false
            messageLabel.stringValue = "自动读取当前不可用，请改为手动选择。"
            messageLabel.textColor = .systemRed
            return
        }
        let bridge = selectedBridge()
        let validationError = bridge.validationError(for: doubao)
        saveButton.isEnabled = doubao.mode.isSupported && validationError == nil
        if let validationError {
            messageLabel.stringValue = validationError
            messageLabel.textColor = .systemRed
        } else {
            messageLabel.stringValue = "本机测试入口会打开 TextEdit；请在其中用豆包自己的按键验证识别。远程粘贴仍需在 UU 远控中验证。"
            messageLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func saveConfiguration() {
        guard let (doubao, manualMode) = selectedDoubaoMode() else {
            messageLabel.stringValue = "自动读取当前不可用，请改为手动选择。"
            messageLabel.textColor = .systemRed
            return
        }
        let bridge = selectedBridge()
        guard let validationError = bridge.validationError(for: doubao) else {
            guard let result = onSave?(doubao, manualMode, doubao.shortcut, bridge) else {
                messageLabel.stringValue = "配置未保存，请重试。"
                messageLabel.textColor = .systemRed
                return
            }
            switch result {
            case .success:
                close()
            case .failure(let error):
                messageLabel.stringValue = error.localizedDescription
                messageLabel.textColor = .systemRed
            }
            return
        }
        messageLabel.stringValue = validationError
        messageLabel.textColor = .systemRed
    }

    @objc private func openPermissions() {
        onOpenPermissions?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.refreshFields()
        }
    }

    @objc private func openLocalTest() {
        onOpenLocalTest?()
    }

    @objc private func recordDoubaoShortcut() {
        startRecording(.doubao)
    }

    @objc private func recordBridgeShortcut() {
        startRecording(.bridge)
    }

    private func startRecording(_ target: RecordingTarget) {
        stopRecording(removeMonitor: true)
        recordingTarget = target
        recordingModifierKeyCodes.removeAll()
        recordingUsedMultipleModifiers = false
        recordingFunctionKeyState.reset()
        recorderKeyUpsToSwallow.removeAll()
        let title = target == .doubao ? "请按下豆包当前使用的按键…" : "请按住要作为远控触发键的按键…"
        messageLabel.stringValue = "\(title) 按 Esc 取消；组合键请同时按住修饰键和主键。"
        messageLabel.textColor = .secondaryLabelColor
        let handler = ShortcutRecorderMonitorHandler.make(
            windowIsKey: { [weak self] in self?.window?.isKeyWindow == true },
            stop: { [weak self] in self?.stopRecording(removeMonitor: true) },
            consume: { [weak self] event in
                guard let self else { return event }
                return self.consumeRecordingEvent(event)
            }
        )
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged], handler: handler)
        updateRecorderTitles()
    }

    private func stopRecording(removeMonitor: Bool) {
        recordingTarget = nil
        recordingModifierKeyCodes.removeAll()
        recordingUsedMultipleModifiers = false
        recordingFunctionKeyState.reset()
        if removeMonitor, let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
            recorderKeyUpsToSwallow.removeAll()
        }
    }

    private func consumeRecordingEvent(_ event: NSEvent) -> NSEvent? {
        guard let target = recordingTarget else {
            if event.type == .keyUp, recorderKeyUpsToSwallow.remove(event.keyCode) != nil {
                if recorderKeyUpsToSwallow.isEmpty { stopRecording(removeMonitor: true) }
                return nil
            }
            if event.type == .flagsChanged, recorderKeyUpsToSwallow.remove(event.keyCode) != nil {
                if recorderKeyUpsToSwallow.isEmpty { stopRecording(removeMonitor: true) }
                return nil
            }
            return event
        }

        if event.type == .keyDown, event.keyCode == 53 {
            messageLabel.stringValue = "已取消录制；原有按键保持不变。"
            messageLabel.textColor = .secondaryLabelColor
            stopRecording(removeMonitor: true)
            updateRecorderTitles()
            return nil
        }

        if event.type == .flagsChanged {
            let code = event.keyCode
            let isFunction = ShortcutRecorderMonitorHandler.isPhysicalFnTransition(event)
            if isFunction {
                let otherModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
                let transition = recordingFunctionKeyState.transition(
                    isDown: event.modifierFlags.contains(.function),
                    hasOtherModifiers: !event.modifierFlags.intersection(otherModifiers).isEmpty || !recordingModifierKeyCodes.isEmpty
                )
                switch transition {
                case .waitingForRelease:
                    if recordingFunctionKeyState.hasOtherModifier {
                        messageLabel.stringValue = "Fn 只能单独录制，不能与其他修饰键组合。"
                        messageLabel.textColor = .systemRed
                    }
                    return nil
                case .rejectedCombination:
                    messageLabel.stringValue = "Fn 只能单独录制，不能与其他修饰键组合。"
                    messageLabel.textColor = .systemRed
                    return nil
                case .ignored:
                    return nil
                case .accepted:
                    acceptRecordedShortcut(KeyboardShortcut(keyCode: 63), for: target)
                    recordingTarget = nil
                    updateRecorderTitles()
                    stopRecording(removeMonitor: true)
                    return nil
                }
            }
            guard KeyboardShortcut.modifierFlag(for: Int64(code)) != nil else { return event }
            if recordingFunctionKeyState.isDown {
                recordingFunctionKeyState.noteOtherModifierOrKey()
                messageLabel.stringValue = "Fn 只能单独录制，不能与其他修饰键组合。"
                messageLabel.textColor = .systemRed
            }
            if recordingModifierKeyCodes.contains(code) {
                recordingModifierKeyCodes.remove(code)
                if recordingModifierKeyCodes.isEmpty, !recordingUsedMultipleModifiers {
                    acceptRecordedShortcut(KeyboardShortcut(keyCode: code), for: target)
                    recordingTarget = nil
                    updateRecorderTitles()
                    stopRecording(removeMonitor: true)
                }
            } else {
                recordingModifierKeyCodes.insert(code)
                if recordingModifierKeyCodes.count > 1 { recordingUsedMultipleModifiers = true }
            }
            return event
        }

        guard event.type == .keyDown else { return event }
        let modifiers = event.modifierFlags
        if recordingFunctionKeyState.isDown {
            recordingFunctionKeyState.noteOtherModifierOrKey()
            messageLabel.stringValue = "Fn 只能单独录制，不能与其他按键组合。"
            messageLabel.textColor = .systemRed
            return nil
        }
        let mask = Self.shortcutModifierMask(from: modifiers)
        let shortcut = KeyboardShortcut(keyCode: event.keyCode, modifierMask: mask)
        acceptRecordedShortcut(shortcut, for: target)
        recorderKeyUpsToSwallow.insert(event.keyCode)
        recordingTarget = nil
        updateRecorderTitles()
        return nil
    }

    private func acceptRecordedShortcut(_ shortcut: KeyboardShortcut, for target: RecordingTarget) {
        let error: String?
        switch target {
        case .doubao: error = shortcut.doubaoValidationError
        case .bridge: error = shortcut.validationError
        }
        guard let error else {
            switch target {
            case .doubao: selectedDoubaoShortcut = shortcut
            case .bridge:
                selectedBridgeShortcut = shortcut
                if bridgePopup.indexOfSelectedItem != 2 { bridgePopup.selectItem(at: 2) }
            }
            messageLabel.stringValue = "已录制：\(shortcut.displayName)"
            messageLabel.textColor = .secondaryLabelColor
            refreshFields()
            return
        }
        messageLabel.stringValue = error
        messageLabel.textColor = .systemRed
    }

    private static func shortcutModifierMask(from flags: NSEvent.ModifierFlags) -> UInt64 {
        var mask: UInt64 = 0
        if flags.contains(.control) { mask |= CGEventFlags.maskControl.rawValue }
        if flags.contains(.option) { mask |= CGEventFlags.maskAlternate.rawValue }
        if flags.contains(.shift) { mask |= CGEventFlags.maskShift.rawValue }
        if flags.contains(.command) { mask |= CGEventFlags.maskCommand.rawValue }
        return mask
    }

    private func updateRecorderTitles() {
        doubaoRecordButton.title = recordingTarget == .doubao
            ? "正在录制豆包按键…"
            : "录制豆包按键：\(selectedDoubaoShortcut.displayName)"
        bridgeRecordButton.title = recordingTarget == .bridge
            ? "正在录制远控触发键…"
            : "录制远控触发键：\(selectedBridgeShortcut?.displayName ?? "未设置")"
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording(removeMonitor: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard recordingTarget != nil else { return }
        messageLabel.stringValue = "设置窗口失去焦点，已停止录制。"
        messageLabel.textColor = .secondaryLabelColor
        stopRecording(removeMonitor: true)
        updateRecorderTitles()
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
