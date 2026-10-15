import AppKit
import ApplicationServices

enum ShortcutSaveError: Error {
    case message(String)

    var localizedDescription: String {
        switch self {
        case .message(let value): return value
        }
    }
}

final class ShortcutSettingsWindowController: NSWindowController {
    var onSave: ((DoubaoShortcutConfiguration, DoubaoShortcutMode?, BridgeShortcutConfiguration) -> Result<Void, ShortcutSaveError>)?
    var onOpenPermissions: (() -> Void)?
    var onOpenLocalTest: (() -> Void)?

    private let automaticConfiguration: DoubaoShortcutConfiguration?
    private let confirmedConfiguration: DoubaoShortcutConfiguration?
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let doubaoModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bridgePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let automaticSummary = NSTextField(wrappingLabelWithString: "")
    private let permissionsSummary = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "保存并启用", target: nil, action: nil)
    private var initialManualMode: DoubaoShortcutMode?
    private var initialBridgeKind: BridgeShortcutKind

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

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "远控听写设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface(in: window)
        refreshFields()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
            let confirmedKey = confirmedConfiguration.mode == .fnToggle ? "Fn" : "左 Control"
            sourcePopup.item(at: 1)?.title = "上次确认：\(confirmedKey)"
        }

        doubaoModePopup.addItem(withTitle: "Fn · 免按模式：单击开始，任意键结束")
        doubaoModePopup.addItem(withTitle: "左 Control · 长按说话，松开结束")
        doubaoModePopup.target = self
        doubaoModePopup.action = #selector(selectionChanged)
        doubaoModePopup.selectItem(at: initialManualMode == .leftControlHold ? 1 : 0)

        bridgePopup.addItem(withTitle: BridgeShortcutKind.followDoubao.title)
        bridgePopup.addItem(withTitle: BridgeShortcutKind.leftControlHold.title)
        bridgePopup.target = self
        bridgePopup.action = #selector(selectionChanged)
        bridgePopup.selectItem(at: initialBridgeKind == .leftControlHold ? 1 : 0)

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
        let modeLabel = makeSectionLabel("手动配置")
        let bridgeLabel = makeSectionLabel("远控听写触发键")
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
            doubaoModePopup,
            bridgeLabel,
            bridgePopup,
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
        contentView.addSubview(stack)

        for control in [sourcePopup, doubaoModePopup, bridgePopup] {
            control.widthAnchor.constraint(equalToConstant: 570).isActive = true
        }
        for field in [intro, automaticSummary, permissionsSummary, messageLabel] {
            field.widthAnchor.constraint(equalToConstant: 570).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20)
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
        if manual {
            automaticSummary.stringValue = "仅支持 Fn 免按模式，或左 Control 长按模式。选择与你在豆包设置中看到的当前按键一致。"
        } else {
            switch sourcePopup.indexOfSelectedItem {
            case 0:
                if let automaticConfiguration {
                    automaticSummary.stringValue = "\(automaticConfiguration.mode.instruction)\n\(automaticConfiguration.sourceAndTime)"
                } else {
                    automaticSummary.stringValue = "当前没有可确认的自动读取结果；请选择手动配置。"
                }
            case 1:
                if let confirmedConfiguration {
                    automaticSummary.stringValue = "\(confirmedConfiguration.mode.instruction)\n\(confirmedConfiguration.sourceAndTime)"
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
    }

    private func selectedDoubaoMode() -> (DoubaoShortcutConfiguration, DoubaoShortcutMode?)? {
        if sourcePopup.indexOfSelectedItem == 0 {
            guard let automaticConfiguration, automaticConfiguration.mode.isSupported else { return nil }
            return (automaticConfiguration, nil)
        }
        if sourcePopup.indexOfSelectedItem == 1 {
            guard let confirmedConfiguration, confirmedConfiguration.mode.isSupported else { return nil }
            return (confirmedConfiguration, nil)
        }
        let mode: DoubaoShortcutMode = doubaoModePopup.indexOfSelectedItem == 1 ? .leftControlHold : .fnToggle
        return (.manual(mode), mode)
    }

    private func selectedBridge() -> BridgeShortcutConfiguration {
        bridgePopup.indexOfSelectedItem == 1 ? .leftControlHold : .followDoubao
    }

    private func updateSaveButtonState() {
        guard let (doubao, _) = selectedDoubaoMode() else {
            saveButton.isEnabled = false
            return
        }
        let bridge = selectedBridge()
        saveButton.isEnabled = doubao.mode.isSupported && bridge.validationError(for: doubao) == nil
    }

    @objc private func saveConfiguration() {
        guard let (doubao, manualMode) = selectedDoubaoMode() else {
            messageLabel.stringValue = "自动读取当前不可用，请改为手动选择。"
            messageLabel.textColor = .systemRed
            return
        }
        let bridge = selectedBridge()
        guard let validationError = bridge.validationError(for: doubao) else {
            guard let result = onSave?(doubao, manualMode, bridge) else {
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
}
