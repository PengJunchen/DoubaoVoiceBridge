import AppKit
import ApplicationServices
import os.log

enum ControlMonitorError: LocalizedError {
    case eventTapUnavailable
    case shortcutUnavailable

    var errorDescription: String? {
        switch self {
        case .eventTapUnavailable:
            return "无法创建键盘监听，请检查辅助功能和输入监控权限"
        case .shortcutUnavailable:
            return "尚未读取到受支持的豆包语音快捷键"
        }
    }
}

final class ControlHoldMonitor {
    static let syntheticEventMarker: Int64 = 0x4456_4252
    private static let leftControlKeyCode: Int64 = 59

    private let holdThreshold: TimeInterval
    private let targetProvider: () -> UURemoteTarget?
    private let targetProviderDiagnostic: () -> String
    private let targetIsActive: (UURemoteTarget) -> Bool
    private let localComposerReady: () -> Bool
    private let onBegin: (UURemoteTarget, ShortcutProfile) -> Void
    private let onFnToggleMayBeActive: () -> Void
    private let onRelease: () -> Void
    private let onCancel: () -> Void
    private let logger = Logger(subsystem: "com.lyp.DoubaoVoiceBridge", category: "control")

    private(set) var profile: ShortcutProfile?
    private var configuration: DoubaoShortcutConfiguration? { profile?.doubao }
    private var gesture = HoldGestureState()
    private var fnGesture = FnToggleGestureState()
    private var target: UURemoteTarget?
    private var activeProfile: ShortcutProfile?
    private var activationWorkItem: DispatchWorkItem?
    private var syntheticDownWorkItem: DispatchWorkItem?
    private var syntheticFnTapReleaseWorkItem: DispatchWorkItem?
    private var syntheticDownPosted = false
    private var syntheticFnDownPosted = false
    private var syntheticFnTapWorkItem: DispatchWorkItem?
    private var syntheticLocalFnToggleActive = false
    private var finishRequestedDuringSyntheticFnTap = false
    private var syntheticDownAt: Date?
    private var syntheticRoute: SyntheticControlRoute?
    private var localFocusDeadline: Date?
    private var fnFocusDeadline: Date?
    private var fnReadinessRetryCount = 0
    private var releaseRequestedBeforeSyntheticDown = false
    private var physicalLeftControlIsDown = false
    private var physicalRightControlIsDown = false
    private var physicalFnIsDown = false
    private var suppressPhysicalFnRelease = false
    private var physicalModifierKeyCodes: Set<Int64> = []
    private var suppressedFnKeyUps = SuppressedKeyTransitions()
    private var fnCompanionKeySuppression = FnCompanionKeySuppression()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var activeTapLocation: CGEventTapLocation?
    var isGestureIdle: Bool { gesture.phase == .idle && fnGesture.phase == .idle }

    init(
        profile: ShortcutProfile?,
        holdThreshold: TimeInterval,
        targetProvider: @escaping () -> UURemoteTarget?,
        targetProviderDiagnostic: @escaping () -> String,
        targetIsActive: @escaping (UURemoteTarget) -> Bool,
        localComposerReady: @escaping () -> Bool,
        onBegin: @escaping (UURemoteTarget, ShortcutProfile) -> Void,
        onFnToggleMayBeActive: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.profile = profile
        self.holdThreshold = min(max(holdThreshold, 0.18), 0.60)
        self.targetProvider = targetProvider
        self.targetProviderDiagnostic = targetProviderDiagnostic
        self.targetIsActive = targetIsActive
        self.localComposerReady = localComposerReady
        self.onBegin = onBegin
        self.onFnToggleMayBeActive = onFnToggleMayBeActive
        self.onRelease = onRelease
        self.onCancel = onCancel
    }

    deinit {
        stop()
    }

    func start() throws {
        guard eventTap == nil else { return }
        guard profile?.isSupported == true else {
            throw ControlMonitorError.shortcutUnavailable
        }

        let eventTypes: [CGEventType] = [
            .flagsChanged,
            .keyDown,
            .keyUp,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel
        ]
        let eventMask = eventTypes.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ControlHoldMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handle(proxy: proxy, type: type, event: event)
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: userInfo
        ) else {
            throw ControlMonitorError.eventTapUnavailable
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw ControlMonitorError.eventTapUnavailable
        }

        eventTap = tap
        activeTapLocation = .cghidEventTap
        refreshPhysicalKeyStates()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.notice("HID event tap started at head")
    }

    func stop() {
        resetGesture(notifyCancel: true)
        resetFnToggle(notifyCancel: true)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        eventTap = nil
        activeTapLocation = nil
    }

    func updateProfile(_ newProfile: ShortcutProfile?) {
        guard isGestureIdle else { return }
        profile = newProfile
    }

    func cancelActiveSession(event: ComposerInputEventMetadata) {
        logger.notice("Panel cancellation received reason=Escape type=\(event.type, privacy: .public) keyCode=\(event.keyCode, privacy: .public) flags=0x\(event.flagsHex, privacy: .public) sourcePID=\(event.sourcePID, privacy: .public) controlPhase=\(String(describing: self.gesture.phase), privacy: .public) fnPhase=\(String(describing: self.fnGesture.phase), privacy: .public) physicalFnDown=\(self.physicalFnIsDown, privacy: .public) syntheticFnDownPosted=\(self.syntheticFnDownPosted, privacy: .public)")
        resetGesture(notifyCancel: false)
        resetFnToggle(notifyCancel: false)
        onCancel()
    }

    func cancelIfFocusLost() {
        guard let target, !targetIsActive(target) else { return }
        if fnGesture.phase == .pendingClick {
            logger.notice("Pending Fn click cancelled because focus left UU and the bridge")
            resetFnToggle(notifyCancel: false)
        } else if fnGesture.phase == .starting || fnGesture.phase == .dictating {
            logger.notice("Fn-toggle session cancelled because focus left UU and the bridge")
            resetFnToggle(notifyCancel: true)
        }
        if gesture.phase == .pending || gesture.phase == .dictating {
            let shouldNotify = gesture.phase == .dictating
            logger.notice("Control-hold session cancelled because focus left UU and the bridge")
            resetGesture(notifyCancel: false)
            if shouldNotify { onCancel() }
        }
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.error("HID event tap disabled; re-enabling (reason=\(type.rawValue, privacy: .public))")
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            let pendingFnClickWasIntercepted = fnGesture.phase == .pendingClick
            resetGesture(notifyCancel: true)
            resetFnToggle(notifyCancel: true)
            refreshPhysicalKeyStates()
            if !physicalFnIsDown {
                suppressPhysicalFnRelease = false
            } else if pendingFnClickWasIntercepted {
                postSyntheticFnPassthrough(proxy: proxy)
            }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        if profile?.usesFnBridge == true {
            return handleFnToggleEvent(proxy: proxy, type: type, event: event)
        }
        guard profile?.usesLeftControlBridge == true else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged, keyCode == 62 {
            physicalRightControlIsDown.toggle()
            if gesture.phase == .pending {
                beginPassthroughForChord()
            } else if gesture.phase == .dictating {
                onCancel()
                resetGesture(notifyCancel: false)
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .flagsChanged, keyCode == Self.leftControlKeyCode {
            physicalLeftControlIsDown.toggle()
            let isDown = physicalLeftControlIsDown
            if isDown, case .idle = gesture.phase {
                let conflictingFlags: CGEventFlags = [.maskShift, .maskAlternate, .maskCommand, .maskSecondaryFn]
                if physicalRightControlIsDown || !event.flags.intersection(conflictingFlags).isEmpty {
                    return Unmanaged.passUnretained(event)
                }
            }
            return handleLeftControl(isDown: isDown, event: event)
        }

        switch gesture.phase {
        case .pending:
            logger.notice("Control hold became a chord; restoring remote Control passthrough")
            beginPassthroughForChord(proxy: proxy)
        case .idle, .dictating, .passthrough:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleFnToggleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged, keyCode == 63 {
            let isDown = event.flags.contains(.maskSecondaryFn)
            let wasDown = physicalFnIsDown
            physicalFnIsDown = isDown

            if isDown && !wasDown {
                switch fnGesture.phase {
                case .idle:
                    return beginFnToggleClick(event: event)
                case .pendingClick, .starting:
                    return nil
                case .dictating:
                    suppressPhysicalFnRelease = true
                    _ = fnGesture.handle(.fnDown(targetAvailable: true, conflictingModifiersPresent: false))
                    fnCompanionKeySuppression.arm(at: ProcessInfo.processInfo.systemUptime)
                    finishFnToggleSession()
                    return nil
                case .stopping:
                    return nil
                }
            }

            if !isDown && wasDown {
                if suppressPhysicalFnRelease {
                    suppressPhysicalFnRelease = false
                    fnCompanionKeySuppression.arm(at: ProcessInfo.processInfo.systemUptime)
                    return nil
                }
                switch fnGesture.phase {
                case .pendingClick:
                    guard let target, targetIsActive(target),
                          targetProvider()?.processIdentifier == target.processIdentifier else {
                        logger.notice("Fn click passed through because UU lost focus before release")
                        resetFnToggle(notifyCancel: false)
                        postSyntheticFnPassthrough(proxy: proxy)
                        return Unmanaged.passUnretained(event)
                    }
                    let effects = fnGesture.handle(.fnUp)
                    guard effects.contains(.beginDictation) else {
                        resetFnToggle(notifyCancel: false)
                        postSyntheticFnPassthrough(proxy: proxy)
                        return Unmanaged.passUnretained(event)
                    }
                    return beginConfirmedFnToggle()
                case .starting, .dictating, .stopping:
                    return nil
                case .idle:
                    return Unmanaged.passUnretained(event)
                }
            }

            return fnGesture.phase == .idle
                ? Unmanaged.passUnretained(event)
                : nil
        }

        if type == .keyDown || type == .keyUp {
            let companionEventType: FnCompanionKeyEventType = type == .keyDown ? .keyDown : .keyUp
            let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
            if fnCompanionKeySuppression.shouldSuppress(
                type: companionEventType,
                keyCode: keyCode,
                sourcePID: sourcePID,
                at: ProcessInfo.processInfo.systemUptime
            ) {
                logger.notice("Fn companion event suppressed type=\(type.rawValue, privacy: .public) keyCode=\(keyCode, privacy: .public) sourcePID=\(sourcePID, privacy: .public) phase=\(String(describing: self.fnGesture.phase), privacy: .public)")
                return nil
            }
        }

        if type == .keyDown, suppressedFnKeyUps.suppressRepeatedKeyDown(keyCode) {
            return nil
        }
        if type == .keyUp, suppressedFnKeyUps.consumeKeyUp(keyCode) {
            return nil
        }
        if type == .keyUp, fnGesture.phase == .pendingClick {
            logger.notice("Pending Fn click cancelled by an already-pressed key release")
            abortPendingFnClick(proxy: proxy, input: .otherKeyUp)
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let wasDown = physicalModifierKeyCodes.contains(keyCode)
            let isDown = !wasDown
            if isDown {
                physicalModifierKeyCodes.insert(keyCode)
            } else {
                physicalModifierKeyCodes.remove(keyCode)
            }
            if suppressedFnKeyUps.consumeModifierRelease(keyCode: keyCode, wasDown: wasDown, isDown: isDown) {
                return nil
            }

            switch fnGesture.phase {
            case .idle:
                return Unmanaged.passUnretained(event)
            case .pendingClick:
                abortPendingFnClick(proxy: proxy)
                return Unmanaged.passUnretained(event)
            case .starting:
                if isDown {
                    logFnStartingInterruption(reason: "modifier-down", type: type, event: event)
                    suppressedFnKeyUps.suppressThroughKeyUp(keyCode)
                    cancelFnToggleSession()
                }
                return nil
            case .dictating:
                if isDown {
                    fnCompanionKeySuppression.arm(at: ProcessInfo.processInfo.systemUptime)
                    suppressedFnKeyUps.suppressThroughKeyUp(keyCode)
                    _ = fnGesture.handle(.otherKeyDown)
                    finishFnToggleSession()
                }
                return nil
            case .stopping:
                if isDown { suppressedFnKeyUps.suppressThroughKeyUp(keyCode) }
                return nil
            }
        }

        if type == .keyDown {
            switch fnGesture.phase {
            case .idle:
                return Unmanaged.passUnretained(event)
            case .pendingClick:
                abortPendingFnClick(proxy: proxy)
                return Unmanaged.passUnretained(event)
            case .starting:
                logFnStartingInterruption(reason: "key-down", type: type, event: event)
                suppressedFnKeyUps.suppressThroughKeyUp(keyCode)
                cancelFnToggleSession()
                return nil
            case .dictating:
                fnCompanionKeySuppression.arm(at: ProcessInfo.processInfo.systemUptime)
                suppressedFnKeyUps.suppressThroughKeyUp(keyCode)
                _ = fnGesture.handle(.otherKeyDown)
                finishFnToggleSession()
                return nil
            case .stopping:
                suppressedFnKeyUps.suppressThroughKeyUp(keyCode)
                return nil
            }
        }

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown || type == .scrollWheel {
            if fnGesture.phase == .pendingClick {
                abortPendingFnClick(proxy: proxy)
            }
            return Unmanaged.passUnretained(event)
        }
        if fnGesture.phase == .pendingClick || fnGesture.phase == .starting || fnGesture.phase == .dictating || fnGesture.phase == .stopping {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func beginFnToggleClick(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let profile,
              profile.usesFnBridge,
              let target = targetProvider() else {
            logger.notice("Fn shortcut passed through because targetProvider returned nil; \(self.targetProviderDiagnostic(), privacy: .public)")
            return Unmanaged.passUnretained(event)
        }
        let conflictingFlags: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        let effects = fnGesture.handle(.fnDown(
            targetAvailable: true,
            conflictingModifiersPresent: !event.flags.intersection(conflictingFlags).isEmpty
        ))
        guard effects.contains(.suppress) else {
            return Unmanaged.passUnretained(event)
        }

        self.target = target
        activeProfile = profile
        fnCompanionKeySuppression.arm(at: ProcessInfo.processInfo.systemUptime)
        logger.notice("Physical Fn down held briefly to distinguish a click from a native Fn chord")
        return nil
    }

    private func beginConfirmedFnToggle() -> Unmanaged<CGEvent>? {
        guard let target, let profile = activeProfile ?? self.profile else {
            resetFnToggle(notifyCancel: false)
            return nil
        }
        guard profile.usesFnBridge, targetIsActive(target) else {
            logger.notice("Confirmed Fn click cancelled because its target is no longer active")
            resetFnToggle(notifyCancel: false)
            onCancel()
            return nil
        }
        fnCompanionKeySuppression.arm(at: ProcessInfo.processInfo.systemUptime)
        target.captureFocusedWindow()
        logger.notice("Physical Fn click confirmed; opening local dictation")
        onBegin(target, profile)
        fnFocusDeadline = Date().addingTimeInterval(0.75)
        fnReadinessRetryCount = 0
        scheduleSyntheticFnTap(after: 0.03)
        return nil
    }

    private func abortPendingFnClick(
        proxy: CGEventTapProxy,
        input: FnToggleInput = .otherKeyDown
    ) {
        guard fnGesture.phase == .pendingClick else { return }
        logger.notice("Fn chord detected before release; restoring the native Fn modifier")
        let effects = fnGesture.handle(input)
        guard effects.contains(.restoreFnPassthrough) else { return }
        fnCompanionKeySuppression.disarm()
        fnGesture.reset()
        target = nil
        activeProfile = nil
        postSyntheticFnPassthrough(proxy: proxy)
    }

    private func postSyntheticFnPassthrough(proxy: CGEventTapProxy) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(source: source) else { return }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: 63)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        event.flags = [.maskSecondaryFn]
        event.tapPostEvent(proxy)
    }

    private func scheduleSyntheticFnTap(after delay: TimeInterval) {
        syntheticDownWorkItem?.cancel()
        if delay >= 0.03 {
            logger.notice("Scheduled synthetic Fn activation check delayMs=\(Int(delay * 1_000), privacy: .public) phase=\(String(describing: self.fnGesture.phase), privacy: .public)")
        }
        let workItem = DispatchWorkItem { [weak self] in self?.postSyntheticFnTapIfReady() }
        syntheticDownWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func postSyntheticFnTapIfReady() {
        guard fnGesture.phase == .starting else {
            logger.notice("Synthetic Fn activation check skipped phase=\(String(describing: self.fnGesture.phase), privacy: .public) syntheticDownPosted=\(self.syntheticFnDownPosted, privacy: .public)")
            return
        }
        guard !syntheticFnDownPosted else {
            logger.notice("Synthetic Fn activation check skipped because Fn down is already posted phase=\(String(describing: self.fnGesture.phase), privacy: .public) syntheticDownPosted=\(self.syntheticFnDownPosted, privacy: .public)")
            return
        }
        guard localComposerReady() else {
            fnReadinessRetryCount += 1
            if fnReadinessRetryCount == 1 || fnReadinessRetryCount.isMultiple(of: 10) {
                logger.notice("Local composer readiness pending attempt=\(self.fnReadinessRetryCount, privacy: .public) phase=\(String(describing: self.fnGesture.phase), privacy: .public)")
            }
            if Date() < fnFocusDeadline ?? .distantPast {
                scheduleSyntheticFnTap(after: 0.02)
            } else {
                logger.error("Local composer did not become ready; cancelling Fn-toggle dictation (attempts=\(self.fnReadinessRetryCount, privacy: .public))")
                cancelFnToggleSession()
            }
            return
        }
        logger.notice("Local composer ready for synthetic Fn activation after retries=\(self.fnReadinessRetryCount, privacy: .public)")
        guard postSyntheticFn(down: true) else {
            logger.error("Unable to post synthetic local Fn down")
            cancelFnToggleSession()
            return
        }
        syntheticFnDownPosted = true
        let effects = fnGesture.handle(.localFnDownPosted)
        if effects.contains(.markDictationMayBeActive) {
            // The input method may toggle on key-down, before this tap's delayed key-up.
            onFnToggleMayBeActive()
        }
        let releaseWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.fnGesture.phase == .starting else {
                self.logger.notice("Synthetic Fn release callback skipped phase=\(String(describing: self.fnGesture.phase), privacy: .public) syntheticFnDownPosted=\(self.syntheticFnDownPosted, privacy: .public)")
                return
            }
            guard self.postSyntheticFn(down: false) else {
                self.logger.error("Unable to post synthetic local Fn up")
                self.cancelFnToggleSession()
                return
            }
            self.syntheticFnDownPosted = false
            _ = self.fnGesture.handle(.localFnTapPosted)
            self.syntheticDownWorkItem = nil
            self.syntheticFnTapReleaseWorkItem = nil
            self.fnFocusDeadline = nil
            self.logger.notice("Synthetic local Fn toggle tap posted")
        }
        syntheticFnTapReleaseWorkItem = releaseWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: releaseWorkItem)
    }

    private func finishFnToggleSession() {
        guard fnGesture.phase == .stopping,
              localComposerReady(),
              postSyntheticAnyKeyToLocalComposer() else {
            logger.error("Unable to deliver the configured any-key stop to the local composer")
            resetFnToggle(notifyCancel: false)
            onCancel()
            return
        }
        logger.notice("Synthetic local any-key stop posted; waiting for transcript")
        resetFnToggle(notifyCancel: false)
        onRelease()
    }

    private func cancelFnToggleSession() {
        resetFnToggle(notifyCancel: false)
        onCancel()
    }

    private func resetFnToggle(notifyCancel: Bool) {
        let wasPendingClick = fnGesture.phase == .pendingClick
        let wasActive = fnGesture.phase == .starting || fnGesture.phase == .dictating || fnGesture.phase == .stopping
        logger.notice("Fn toggle reset phase=\(String(describing: self.fnGesture.phase), privacy: .public) active=\(wasActive, privacy: .public) notifyCancel=\(notifyCancel, privacy: .public) syntheticFnDownPosted=\(self.syntheticFnDownPosted, privacy: .public)")
        if wasPendingClick {
            fnCompanionKeySuppression.disarm()
        }
        syntheticDownWorkItem?.cancel()
        syntheticFnTapReleaseWorkItem?.cancel()
        if syntheticFnDownPosted {
            _ = postSyntheticFn(down: false)
        }
        syntheticDownWorkItem = nil
        syntheticFnTapReleaseWorkItem = nil
        syntheticFnDownPosted = false
        fnFocusDeadline = nil
        fnReadinessRetryCount = 0
        fnGesture.reset()
        activeProfile = nil
        target = nil
        if notifyCancel && wasActive { onCancel() }
    }

    private func logFnStartingInterruption(reason: String, type: CGEventType, event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let flags = String(event.flags.rawValue, radix: 16)
        logger.notice("Fn startup interrupted reason=\(reason, privacy: .public) type=\(type.rawValue, privacy: .public) keyCode=\(keyCode, privacy: .public) flags=0x\(flags, privacy: .public) sourcePID=\(sourcePID, privacy: .public) phase=\(String(describing: self.fnGesture.phase), privacy: .public)")
    }

    @discardableResult
    private func postSyntheticFn(down: Bool) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(source: source) else { return false }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: 63)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        // The physical bridge shortcut can still be held. A synthetic Fn
        // intended for Doubao must never inherit that Control modifier.
        event.flags = SyntheticShortcutEventFlags.fnToggle(down: down)
        event.post(tap: .cgSessionEventTap)
        return true
    }

    @discardableResult
    private func postSyntheticAnyKeyToLocalComposer() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 105, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 105, keyDown: false) else {
            return false
        }
        keyDown.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        keyUp.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        keyDown.flags = []
        keyUp.flags = []
        let processID = ProcessInfo.processInfo.processIdentifier
        keyDown.postToPid(processID)
        keyUp.postToPid(processID)
        return true
    }

    private func refreshPhysicalKeyStates() {
        physicalLeftControlIsDown = CGEventSource.keyState(
            .combinedSessionState,
            key: CGKeyCode(Self.leftControlKeyCode)
        )
        physicalRightControlIsDown = CGEventSource.keyState(.combinedSessionState, key: 62)
        physicalFnIsDown = CGEventSource.keyState(.combinedSessionState, key: 63)
        physicalModifierKeyCodes = Set(
            [54, 55, 56, 57, 58, 59, 60, 61, 62].compactMap { keyCode -> Int64? in
                CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)) ? Int64(keyCode) : nil
            }
        )
    }

    private func handleLeftControl(isDown: Bool, event: CGEvent) -> Unmanaged<CGEvent>? {
        if isDown {
            guard case .idle = gesture.phase else {
                return gesture.phase == .passthrough ? Unmanaged.passUnretained(event) : nil
            }
            guard let target = targetProvider() else {
                logger.notice("Left Control passed through because UU is not eligible")
                return Unmanaged.passUnretained(event)
            }

            logger.notice("Physical left Control down intercepted for local dictation")
            self.target = target
            activeProfile = profile
            _ = gesture.handle(.controlDown(targetAvailable: true))
            let workItem = DispatchWorkItem { [weak self] in self?.activateDictationIfStillPending() }
            activationWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
            return nil
        }

        switch gesture.phase {
        case .idle:
            return Unmanaged.passUnretained(event)
        case .pending:
            logger.notice("Physical left Control released before long-press threshold")
            _ = gesture.handle(.controlUp)
            resetGesture(notifyCancel: false)
            return nil
        case .passthrough:
            _ = gesture.handle(.controlUp)
            // The real left-Control release is about to pass through, so it
            // completes the synthetic down used to recover the chord.
            syntheticDownPosted = false
            resetGesture(notifyCancel: false)
            return Unmanaged.passUnretained(event)
        case .dictating:
            logger.notice("Physical left Control released; finishing local dictation")
            _ = gesture.handle(.controlUp)
            finishDictationGesture()
            return nil
        }
    }

    private func activateDictationIfStillPending() {
        guard case .pending = gesture.phase, let target else { return }
        guard !physicalRightControlIsDown,
              targetProvider()?.processIdentifier == target.processIdentifier else {
            logger.notice("Long-press cancelled because UU is no longer the eligible target")
            resetGesture(notifyCancel: false)
            return
        }
        _ = gesture.handle(.thresholdReached)
        target.captureFocusedWindow()
        logger.notice("Long-press threshold reached; opening local composer")
        guard let activeProfile else {
            resetGesture(notifyCancel: false)
            return
        }
        onBegin(target, activeProfile)
        localFocusDeadline = Date().addingTimeInterval(0.75)
        scheduleSyntheticDownCheck(after: 0.03)
    }

    private func postSyntheticDownIfNeeded() {
        guard case .dictating = gesture.phase,
              !syntheticDownPosted,
              !syntheticFnDownPosted,
              syntheticFnTapWorkItem == nil else { return }
        if releaseRequestedBeforeSyntheticDown {
            onCancel()
            resetGesture(notifyCancel: false)
            return
        }
        guard localComposerReady() else {
            if Date() < localFocusDeadline ?? .distantPast {
                scheduleSyntheticDownCheck(after: 0.02)
            } else {
                logger.error("Local composer did not become ready; cancelling dictation")
                onCancel()
                resetGesture(notifyCancel: false)
            }
            return
        }
        logger.notice("Local composer is key and ready for Doubao voice input method")
        guard let activeProfile else {
            onCancel()
            resetGesture(notifyCancel: false)
            return
        }
        if activeProfile.doubao.mode == .fnToggle {
            guard postSyntheticFn(down: true) else {
                logger.error("Unable to create synthetic local Fn down for Control bridge")
                onCancel()
                resetGesture(notifyCancel: false)
                return
            }
            syntheticFnDownPosted = true
            onFnToggleMayBeActive()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.syntheticFnDownPosted else { return }
                guard self.postSyntheticFn(down: false) else {
                    self.logger.error("Unable to create synthetic local Fn up for Control bridge")
                    self.onCancel()
                    self.resetGesture(notifyCancel: false)
                    return
                }
                self.syntheticFnDownPosted = false
                self.syntheticFnTapWorkItem = nil
                self.syntheticLocalFnToggleActive = true
                self.logger.notice("Synthetic local Fn toggle tap posted for Control bridge")
                if self.finishRequestedDuringSyntheticFnTap {
                    self.finishRequestedDuringSyntheticFnTap = false
                    self.finishLocalFnToggleFromControlRelease()
                }
            }
            syntheticFnTapWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: workItem)
            return
        }

        let route = SyntheticControlRoute.localSessionDictation
        guard postSyntheticControl(down: true, route: route) else {
            logger.error("Unable to create synthetic local Control down")
            onCancel()
            resetGesture(notifyCancel: false)
            return
        }
        syntheticDownPosted = true
        syntheticDownAt = Date()
        syntheticRoute = route
        logger.notice("Synthetic local Control down posted at session tap")
    }

    private func scheduleSyntheticDownCheck(after delay: TimeInterval) {
        syntheticDownWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.postSyntheticDownIfNeeded() }
        syntheticDownWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func finishDictationGesture() {
        if syntheticLocalFnToggleActive {
            finishLocalFnToggleFromControlRelease()
            return
        }
        if syntheticFnDownPosted, syntheticFnTapWorkItem != nil {
            finishRequestedDuringSyntheticFnTap = true
            return
        }
        if syntheticDownPosted {
            if let syntheticRoute {
                postSyntheticControl(down: false, route: syntheticRoute)
            }
            syntheticDownPosted = false
            let heldLongEnough = Date().timeIntervalSince(syntheticDownAt ?? .distantPast) >= 0.15
            if heldLongEnough {
                logger.notice("Local Doubao voice input method gesture completed; waiting for transcript")
                onRelease()
            } else {
                logger.notice("Synthetic local Control hold was too short; cancelling")
                onCancel()
            }
            resetGesture(notifyCancel: false)
        } else {
            releaseRequestedBeforeSyntheticDown = true
        }
    }

    private func finishLocalFnToggleFromControlRelease() {
        guard syntheticLocalFnToggleActive,
              localComposerReady(),
              postSyntheticAnyKeyToLocalComposer() else {
            logger.error("Unable to deliver the configured any-key stop to the local composer")
            syntheticLocalFnToggleActive = false
            onCancel()
            resetGesture(notifyCancel: false)
            return
        }
        syntheticLocalFnToggleActive = false
        logger.notice("Synthetic local any-key stop posted for Control bridge; waiting for transcript")
        onRelease()
        resetGesture(notifyCancel: false)
    }

    private func beginPassthroughForChord(proxy: CGEventTapProxy? = nil) {
        guard case .pending = gesture.phase else { return }
        activationWorkItem?.cancel()
        activationWorkItem = nil
        _ = gesture.handle(.otherInput)
        target = nil
        let route = SyntheticControlRoute.remoteHIDPassthrough
        if postSyntheticControl(down: true, route: route, proxy: proxy) {
            syntheticDownPosted = true
            syntheticRoute = route
        } else {
            logger.error("Unable to recover remote Control chord")
        }
    }

    private func resetGesture(notifyCancel: Bool) {
        let wasDictating = gesture.phase == .dictating
        if syntheticDownPosted, let syntheticRoute {
            postSyntheticControl(down: false, route: syntheticRoute)
        }
        if syntheticFnDownPosted {
            _ = postSyntheticFn(down: false)
        }
        activationWorkItem?.cancel()
        syntheticDownWorkItem?.cancel()
        syntheticFnTapWorkItem?.cancel()
        activationWorkItem = nil
        syntheticDownWorkItem = nil
        syntheticDownPosted = false
        syntheticFnDownPosted = false
        syntheticFnTapWorkItem = nil
        syntheticLocalFnToggleActive = false
        finishRequestedDuringSyntheticFnTap = false
        syntheticDownAt = nil
        syntheticRoute = nil
        localFocusDeadline = nil
        releaseRequestedBeforeSyntheticDown = false
        gesture.reset()
        target = nil
        activeProfile = nil
        if notifyCancel && wasDictating { onCancel() }
    }

    @discardableResult
    private func postSyntheticControl(
        down: Bool,
        route: SyntheticControlRoute,
        proxy: CGEventTapProxy? = nil
    ) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(source: source) else { return false }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Self.leftControlKeyCode)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        var flags = CGEventSource.flagsState(.combinedSessionState)
        if down {
            flags.insert(.maskControl)
        } else if !physicalRightControlIsDown {
            flags.remove(.maskControl)
        }
        event.flags = flags
        if route == .remoteHIDPassthrough, let proxy {
            event.tapPostEvent(proxy)
        } else {
            event.post(tap: route.eventTapLocation)
        }
        return true
    }
}

enum SyntheticControlRoute: Equatable {
    case remoteHIDPassthrough
    case localSessionDictation

    var eventTapLocation: CGEventTapLocation {
        switch self {
        case .remoteHIDPassthrough:
            return .cghidEventTap
        case .localSessionDictation:
            return .cgSessionEventTap
        }
    }
}
