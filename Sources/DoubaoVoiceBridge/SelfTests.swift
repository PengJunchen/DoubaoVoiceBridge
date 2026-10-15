import Foundation
import CoreGraphics
import AppKit

enum SelfTests {
    static func run() -> Bool {
        var failures: [String] = []

        func check<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
            if actual != expected {
                failures.append("\(label): expected \(expected), got \(actual)")
            }
        }

        do {
            var state = HoldGestureState()
            check(state.handle(.controlDown(targetAvailable: true)), [.suppress, .scheduleThreshold], "long hold down")
            check(state.phase, .pending, "long hold pending")
            check(state.handle(.thresholdReached), [.beginDictation], "long hold threshold")
            check(state.phase, .dictating, "long hold dictating")
            check(state.handle(.controlUp), [.suppress, .finishDictation], "long hold release")
            state.reset()
            check(state.phase, .idle, "long hold idle")
        }

        do {
            var state = HoldGestureState()
            _ = state.handle(.controlDown(targetAvailable: true))
            check(state.handle(.otherInput), [.synthesizeControlDown, .passThrough], "chord recovery")
            check(state.phase, .passthrough, "chord passthrough")
            check(state.handle(.controlUp), [.passThrough], "chord release")
            check(state.phase, .idle, "chord idle")
        }

        do {
            var state = HoldGestureState()
            check(state.handle(.controlDown(targetAvailable: false)), [.passThrough], "non-UU down")
            check(state.phase, .idle, "non-UU idle")
            check(state.handle(.controlUp), [.passThrough], "non-UU release")
        }

        do {
            var state = FnToggleGestureState()
            check(
                state.handle(.fnDown(targetAvailable: false, conflictingModifiersPresent: false)),
                [.passThrough],
                "Fn shortcut passes through without a valid UU target"
            )
            check(
                state.handle(.fnDown(targetAvailable: true, conflictingModifiersPresent: true)),
                [.passThrough],
                "Fn pressed after a modifier passes through as a native chord"
            )
            check(state.phase, .idle, "modifier chord leaves Fn state idle")
            check(
                state.handle(.fnDown(targetAvailable: true, conflictingModifiersPresent: false)),
                [.suppress],
                "Fn down waits for release to distinguish a click from a chord"
            )
            check(state.phase, .pendingClick, "Fn press remains pending until physical release")
            check(
                state.handle(.otherKeyDown),
                [.restoreFnPassthrough, .passThrough],
                "Fn plus another key restores the Fn modifier and passes the key through"
            )
            check(state.phase, .idle, "native Fn chord leaves toggle state idle")
            _ = state.handle(.fnDown(targetAvailable: true, conflictingModifiersPresent: false))
            check(
                state.handle(.otherKeyUp),
                [.restoreFnPassthrough, .passThrough],
                "a key released after Fn went down aborts the pending click and passes its release"
            )
            check(state.phase, .idle, "pre-existing key release leaves Fn idle")
            check(state.handle(.fnUp), [.passThrough], "the later physical Fn release stays native after the chord abort")
            check(state.phase, .idle, "an aborted Fn chord cannot start dictation on release")
            _ = state.handle(.fnDown(targetAvailable: true, conflictingModifiersPresent: false))
            check(
                state.handle(.fnUp),
                [.suppress, .beginDictation],
                "Fn release confirms a standalone click and begins dictation"
            )
            check(state.phase, .starting, "Fn stays starting until local tap posts")
            check(state.handle(.fnUp), [.suppress], "Fn trigger release does not finish dictation")
            check(state.phase, .starting, "Fn release leaves the toggle session active")
            check(
                state.handle(.localFnDownPosted),
                [.markDictationMayBeActive],
                "cancellation treats the interval after synthetic Fn down as possibly recording"
            )
            check(state.phase, .starting, "synthetic Fn down keeps the gesture in its start phase")
            check(state.handle(.localFnTapPosted), [], "local Fn tap activates Doubao")
            check(state.phase, .dictating, "Fn local tap enters dictation")
            check(state.handle(.fnUp), [.suppress], "Fn release during toggle dictation does not finish it")
            check(state.phase, .dictating, "Fn release preserves active toggle dictation")
            check(state.handle(.otherKeyDown), [.suppress, .finishDictation], "any key ends Fn dictation")
            check(state.phase, .stopping, "Fn any-key stop enters stopping state")
            _ = state.handle(.cancel)
            check(state.phase, .idle, "Fn cancellation returns to idle")
        }

        do {
            var suppressed = SuppressedKeyTransitions()
            check(suppressed.suppressRepeatedKeyDown(49), false, "stop-key first down is handled by the gesture")
            suppressed.suppressThroughKeyUp(49)
            check(suppressed.suppressRepeatedKeyDown(49), true, "held stop key repeat down stays suppressed")
            check(suppressed.consumeKeyUp(49), true, "stop-key release is consumed")
            check(suppressed.suppressRepeatedKeyDown(49), false, "keydown passes after paired release")
            suppressed.suppressThroughKeyUp(56)
            check(
                suppressed.consumeModifierRelease(keyCode: 56, wasDown: true, isDown: false),
                true,
                "modifier stop release is consumed from flagsChanged"
            )
            check(suppressed.suppressRepeatedKeyDown(56), false, "modifier release clears suppressed state")
        }

        do {
            var state = FnToggleGestureState()
            var companion = FnCompanionKeySuppression()
            companion.arm(at: 100.0)
            _ = state.handle(.fnDown(targetAvailable: true))
            _ = state.handle(.fnUp)
            check(state.phase, .starting, "recorded Fn click reaches startup before companion event")

            let startEventSuppressed = companion.shouldSuppress(
                type: .keyDown,
                keyCode: 179,
                sourcePID: 0,
                at: 100.011
            )
            check(startEventSuppressed, true, "source-PID-0 key 179 in the Fn startup window is suppressed")
            if !startEventSuppressed {
                _ = state.handle(.otherKeyDown)
            }
            check(state.phase, .starting, "key 179 companion must not cancel the recorded Fn startup")
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 100.30),
                true,
                "key 179 repeats remain suppressed until its matching release"
            )
            check(
                companion.shouldSuppress(type: .keyUp, keyCode: 179, sourcePID: 0, at: 100.31),
                true,
                "matching key 179 release is suppressed even after the initial window"
            )
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 100.32),
                false,
                "key 179 is not permanently swallowed after its paired release"
            )

            companion.arm(at: 150.0)
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 150.01),
                true,
                "source-PID-0 companion down starts a paired suppression"
            )
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 152.02),
                false,
                "unpaired key 179 cannot remain suppressed indefinitely"
            )

            companion.arm(at: 200.0)
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 123, sourcePID: 0, at: 200.01),
                false,
                "Fn plus Arrow remains eligible for native chord passthrough"
            )
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 42, at: 200.01),
                false,
                "key 179 from a non-system source is not suppressed"
            )
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 200.26),
                false,
                "key 179 is not suppressed outside the bounded Fn window"
            )

            companion.arm(at: 225.0)
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 225.01),
                true,
                "swallowed key down starts its matching-release guard"
            )
            companion.disarm()
            check(
                companion.shouldSuppress(type: .keyUp, keyCode: 179, sourcePID: 0, at: 225.02),
                true,
                "disarming the trigger window preserves the matching swallowed key-up"
            )

            state.reset()
            companion.arm(at: 250.0)
            _ = state.handle(.fnDown(targetAvailable: true))
            check(state.handle(.otherKeyDown), [.restoreFnPassthrough, .passThrough], "Fn chord abort restores native passthrough")
            companion.disarm()
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 250.01),
                false,
                "key 179 passes after a native chord abort disarms the pending click window"
            )

            companion.arm(at: 275.0)
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 275.01),
                true,
                "companion key down begins a bounded key-up suppression"
            )
            check(
                companion.shouldSuppress(type: .keyUp, keyCode: 179, sourcePID: 0, at: 277.02),
                false,
                "key-up after the two-second pairing grace is passed and clears pending state"
            )
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 277.03),
                false,
                "expired key-up pairing leaves no stale suppression state"
            )

            state.reset()
            _ = state.handle(.fnDown(targetAvailable: true))
            _ = state.handle(.fnUp)
            _ = state.handle(.localFnDownPosted)
            _ = state.handle(.localFnTapPosted)
            check(state.phase, .dictating, "Fn stop test reaches dictating")
            _ = state.handle(.fnDown(targetAvailable: true))
            companion.arm(at: 300.0)
            state.reset()
            check(
                companion.shouldSuppress(type: .keyDown, keyCode: 179, sourcePID: 0, at: 300.02),
                true,
                "key 179 companion immediately after the Fn stop is suppressed"
            )
        }

        do {
            var state = HoldGestureState()
            _ = state.handle(.controlDown(targetAvailable: true))
            check(state.handle(.controlUp), [.suppress], "quick tap")
            check(state.phase, .idle, "quick tap idle")
        }

        do {
            let flagsMask = CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)
            let uu = InstalledEventTap(
                processIdentifier: 100,
                location: CGEventTapLocation.cghidEventTap.rawValue,
                options: CGEventTapOptions.defaultTap.rawValue,
                eventMask: flagsMask,
                isEnabled: true
            )
            let bridge = InstalledEventTap(
                processIdentifier: 200,
                location: CGEventTapLocation.cghidEventTap.rawValue,
                options: CGEventTapOptions.defaultTap.rawValue,
                eventMask: flagsMask,
                isEnabled: true
            )
            check(
                UURemoteTapOrder.needsReinstall(taps: [uu, bridge], bridgePID: 200, uuRemotePID: 100),
                true,
                "UU tap ahead requires reinstall"
            )
            check(
                UURemoteTapOrder.needsReinstall(taps: [bridge, uu], bridgePID: 200, uuRemotePID: 100),
                false,
                "bridge tap ahead stays installed"
            )
            check(
                UURemoteActivationAudit.delay(previousPID: 100, activatedPID: 100),
                0.25,
                "same-PID UU activation is audited"
            )
            check(
                UURemoteActivationAudit.delay(previousPID: 100, activatedPID: 101),
                0.8,
                "new-PID UU launch gets settle time"
            )
        }

        do {
            check(
                SyntheticControlRoute.localSessionDictation.eventTapLocation.rawValue,
                CGEventTapLocation.cgSessionEventTap.rawValue,
                "local dictation bypasses UU HID tap"
            )
            check(
                SyntheticControlRoute.remoteHIDPassthrough.eventTapLocation.rawValue,
                CGEventTapLocation.cghidEventTap.rawValue,
                "remote Control chords stay on HID path"
            )
        }

        do {
            do {
                let events = try ClipboardKeyboardPaster.makeCommandVEvents()
                check(events.count, 4, "Command-V event count")
                check(
                    events.map(\.type),
                    [.flagsChanged, .keyDown, .keyUp, .flagsChanged],
                    "Command-V event types"
                )
                check(
                    events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                    [55, 9, 9, 55],
                    "Command-V event key codes"
                )
                check(events[0].flags.contains(.maskCommand), true, "Command down flag")
                check(
                    (events[0].flags.rawValue & 0x8) != 0,
                    true,
                    "left Command device flag"
                )
                check(events[1].flags, events[0].flags, "V down inherits Command state")
                check(events[2].flags, events[0].flags, "V up inherits Command state")
                check(events[3].flags.contains(.maskCommand), false, "Command up clears flag")
                check(
                    (events[3].flags.rawValue & 0x8) == 0,
                    true,
                    "Command up clears left device flag"
                )
                check(
                    events.allSatisfy {
                        $0.getIntegerValueField(.eventSourceUserData) ==
                            ControlHoldMonitor.syntheticEventMarker
                    },
                    true,
                    "Command-V events carry bridge marker"
                )
            } catch {
                failures.append("Command-V event creation: \(error)")
            }
        }

        do {
            check(
                DoubaoShortcutSettingsReader.mode(fromVisibleSettingsText: "免按模式：fn，按一次即可开始说话，再按任意键可结束"),
                .fnToggle,
                "visible Doubao settings detect Fn toggle"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "语音输入实时上屏 … 语音输入模式 长按模式 按住说话，松手结束 点击设置 免按模式 按一次即可开始说话，再按任意键可结束 fn 全局唤起语音 离线语音"
                ),
                .fnToggle,
                "actual AX settings text reads the bounded Fn key after the any-key instruction"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "语音输入模式 长按模式 按住说话，松手结束 左 Control 免按模式 按一次即可开始说话，再按任意键可结束"
                ),
                .leftControlHold,
                "visible left Control long-press is detected when the Fn mode has no selected key"
            )
            check(
                DoubaoShortcutSettingsReader.visibleModeCandidates(in: [[
                    "长按模式", "按住说话，松手结束", "点击设置", "免按模式",
                    "按一次即可开始说话", "再按任意键可结束", "Fn", "全局唤起语音",
                    "Ctrl", "离线语音", "未选中的其他快捷键"
                ]]),
                [.fnToggle],
                "split setting nodes aggregate only within the selected mode field"
            )
            check(
                DoubaoShortcutSettingsReader.visibleModeCandidates(in: [[
                    "长按模式", "按住说话，松手结束", "Left Control"
                ]]),
                [.leftControlHold],
                "AX title, instruction and left Control value aggregate across nodes"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "长按模式 按住说话，松手结束 Left ⌃"
                ),
                .leftControlHold,
                "visible left Control glyph is canonicalized to the supported trigger"
            )
            check(
                DoubaoShortcutSettingsReader.shouldCollectShortcutText("Left Control"),
                true,
                "AX collection keeps a standalone English Left Control value"
            )
            check(
                DoubaoShortcutSettingsReader.shouldCollectShortcutText("左 Control"),
                true,
                "AX collection keeps a standalone Chinese left Control value"
            )
            check(
                DoubaoShortcutSettingsReader.shouldCollectShortcutText("⌃"),
                true,
                "AX collection keeps a standalone Control glyph"
            )
            check(
                DoubaoShortcutSettingsReader.shouldCollectShortcutText("Shift"),
                true,
                "AX collection keeps a standalone modifier value"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "长按模式 按住说话，松手结束 ⌃"
                ),
                .unsupported("control"),
                "a bare Control glyph is not assumed to mean left Control"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "长按模式 按住说话，松手结束 Right ⌃"
                ),
                .unsupported("right control"),
                "a right Control glyph is not treated as left Control"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "长按模式 按住说话，松手结束 Right Control"
                ),
                .unsupported("right control"),
                "visible right Control is never mistaken for left Control"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "长按模式 按住说话，松手结束 Control"
                ),
                .unsupported("control"),
                "a generic Control label is not assumed to mean left Control"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "长按模式 按住说话，松手结束 Left Control + Shift"
                ),
                nil,
                "a Control modifier chord is not treated as the supported single-key shortcut"
            )
            check(
                DoubaoShortcutSettingsReader.visibleModeCandidates(in: [[
                    "长按模式", "按住说话", "松手结束", "Left Control", "+", "Shift"
                ]]),
                [],
                "AX filtering retains split Control and Shift values and rejects their chord"
            )
            check(
                DoubaoShortcutSettingsReader.visibleModeCandidates(in: [[
                    "长按模式", "按住说话，松手结束", "全局唤起语音", "Left Control"
                ]]),
                [],
                "an unrelated global shortcut stays outside the long-press settings group"
            )
            check(
                DoubaoShortcutSettingsReader.visibleModeCandidates(in: [[
                    "长按模式", "按住说话，松手结束", "左 Control", "免按模式",
                    "按一次即可开始说话", "再按任意键可结束", "Fn"
                ]]),
                [.leftControlHold, .fnToggle],
                "separate active long-press and Fn modes remain distinct candidates"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "长按模式 按住说话，松手结束 左 Control 免按模式 按一次即可开始说话，再按任意键可结束 Fn"
                ),
                nil,
                "whole settings text with two active shortcut modes is ambiguous"
            )
            check(
                DoubaoShortcutSettingsReader.visibleModeCandidates(in: [
                    ["免按模式", "按一次即可开始说话"],
                    ["再按任意键可结束", "Fn"]
                ]),
                [],
                "AX settings from separate windows are never combined"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "免按模式 按一次即可开始说话，再按任意键可结束 fn+control"
                ),
                nil,
                "conflicting visible shortcut candidates are rejected"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    fromVisibleSettingsText: "免按模式 点击设置 按一次即可开始说话，再按任意键可结束"
                ),
                nil,
                "the settings button label is never treated as a shortcut"
            )
            check(
                DoubaoShortcutSettingsReader.mode(fromVisibleSettingsText: "fn 是可用按键；请打开设置查看"),
                nil,
                "unrelated Fn text is not accepted as a shortcut"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    isStartEnabled: true,
                    isGlobalEnabled: nil,
                    keyCode: 63,
                    keyDisplay: "fn",
                    longPressKeyCode: nil,
                    longPressKeyDisplay: nil,
                    modifierFlags: 0
                ),
                .fnToggle,
                "ASR preference contract detects Fn toggle"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    isStartEnabled: true,
                    isGlobalEnabled: nil,
                    keyCode: 63,
                    keyDisplay: "fn",
                    longPressKeyCode: nil,
                    longPressKeyDisplay: nil,
                    modifierFlags: 1
                ),
                .unsupported("fn"),
                "Fn plus a modifier is not treated as the Fn-only shortcut"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    isStartEnabled: true,
                    isGlobalEnabled: nil,
                    keyCode: 36,
                    keyDisplay: "Return",
                    longPressKeyCode: nil,
                    longPressKeyDisplay: nil,
                    modifierFlags: 0
                ),
                .unsupported("Return"),
                "unknown configured shortcut is not guessed"
            )
            check(
                DoubaoShortcutSettingsReader.mode(
                    isStartEnabled: false,
                    isGlobalEnabled: nil,
                    keyCode: nil,
                    keyDisplay: nil,
                    longPressKeyCode: nil,
                    longPressKeyDisplay: nil,
                    modifierFlags: 0
                ),
                .disabled,
                "disabled ASR shortcut stays disabled"
            )
        }

        do {
            check(PrivacySafeTextMetrics.lengthBucket(0), "empty", "empty length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(4), "1-4", "short length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(16), "5-16", "medium length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(64), "17-64", "long length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(65), "65+", "largest length bucket")
        }

        do {
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: true,
                    hasMarkedText: false,
                    elapsedAfterRelease: 1.0,
                    stableFor: 1.0
                ),
                false,
                "empty transcript never settles"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 0.45,
                    stableFor: 0.35
                ),
                true,
                "settle at optimized thresholds"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: true,
                    elapsedAfterRelease: 1.0,
                    stableFor: 1.0
                ),
                false,
                "marked transcript never settles"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 0.44,
                    stableFor: 1.0
                ),
                false,
                "release grace is preserved"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 1.0,
                    stableFor: 0.34
                ),
                false,
                "tail correction resets stable window"
            )
            check(
                UURemoteDelivery.defaultPasteDelay >= UURemoteDelivery.minimumPasteDelay,
                true,
                "default UU sync delay respects safety floor"
            )
            check(
                LatencyDefaultsMigration.replacementPasteDelay(for: NSNumber(value: 0.9)),
                UURemoteDelivery.defaultPasteDelay,
                "numeric v2.2 delay migrates"
            )
            check(
                LatencyDefaultsMigration.replacementPasteDelay(for: "0.9"),
                UURemoteDelivery.defaultPasteDelay,
                "string v2.2 delay migrates"
            )
            check(
                LatencyDefaultsMigration.replacementPasteDelay(for: NSNumber(value: 0.7)),
                nil,
                "custom delay is preserved"
            )
        }

        do {
            let f5WithFunctionFlag = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.function],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "5",
                charactersIgnoringModifiers: "5",
                isARepeat: false,
                keyCode: 96
            )!
            check(
                ShortcutRecorderMonitorHandler.isPhysicalFnTransition(f5WithFunctionFlag),
                false,
                "AppKit function flag on F5 is not a physical Fn transition"
            )
            let physicalFnTransition = NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: [.function],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 63
            )!
            check(
                ShortcutRecorderMonitorHandler.isPhysicalFnTransition(physicalFnTransition),
                true,
                "only keyCode 63 flagsChanged represents physical Fn"
            )

            var functionKeyState = ShortcutRecorderMonitorHandler.FunctionKeyState()
            check(
                functionKeyState.transition(isDown: true, hasOtherModifiers: false),
                .waitingForRelease,
                "Fn recording waits through the physical release"
            )
            functionKeyState.noteOtherModifierOrKey()
            check(
                functionKeyState.transition(isDown: false, hasOtherModifiers: false),
                .rejectedCombination,
                "Fn plus a modifier is rejected after observing the full chord"
            )
            check(
                functionKeyState.transition(isDown: true, hasOtherModifiers: false),
                .waitingForRelease,
                "a fresh standalone Fn attempt can follow a rejected chord"
            )
            check(
                functionKeyState.transition(isDown: false, hasOtherModifiers: false),
                .accepted,
                "standalone Fn is accepted on release"
            )

            let recorderEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "q",
                charactersIgnoringModifiers: "q",
                isARepeat: false,
                keyCode: 12
            )!
            var consumeCalled = false
            let keyWindowHandler = ShortcutRecorderMonitorHandler.make(
                windowIsKey: { true },
                stop: {},
                consume: { _ in consumeCalled = true; return nil }
            )
            let consumedResult = keyWindowHandler(recorderEvent)
            check(consumedResult.map { _ in false } ?? true, true, "recorder local-monitor closure preserves intentional nil")
            check(consumeCalled, true, "recorder local-monitor closure reaches its event consumer")

            var stoppedAfterFocusLoss = false
            let focusLostHandler = ShortcutRecorderMonitorHandler.make(
                windowIsKey: { false },
                stop: { stoppedAfterFocusLoss = true },
                consume: { _ in nil }
            )
            check(focusLostHandler(recorderEvent) === recorderEvent, true, "focus loss forwards the current event")
            check(stoppedAfterFocusLoss, true, "focus loss stops the recorder and removes its monitor")

            let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
            textView.string = "已有听写正文"
            var commitCount = 0
            textView.onCommit = { commitCount += 1 }
            textView.observesControlRelease = true
            var cancelCount = 0
            textView.onCancel = { _ in cancelCount += 1 }
            let syntheticSource = CGEventSource(stateID: .combinedSessionState)!
            let syntheticLetter = CGEvent(keyboardEventSource: syntheticSource, virtualKey: 0, keyDown: true)!
            syntheticLetter.setIntegerValueField(.eventSourceUserData, value: ControlHoldMonitor.syntheticEventMarker)
            textView.keyDown(with: NSEvent(cgEvent: syntheticLetter)!)
            check(textView.string, "已有听写正文", "marked synthetic voice key cannot overwrite existing composer text")
            let syntheticReturn = CGEvent(keyboardEventSource: syntheticSource, virtualKey: 36, keyDown: true)!
            syntheticReturn.setIntegerValueField(.eventSourceUserData, value: ControlHoldMonitor.syntheticEventMarker)
            textView.keyDown(with: NSEvent(cgEvent: syntheticReturn)!)
            check(commitCount, 0, "marked synthetic voice Return cannot commit the composer")
            let syntheticEscape = CGEvent(keyboardEventSource: syntheticSource, virtualKey: 53, keyDown: true)!
            syntheticEscape.setIntegerValueField(.eventSourceUserData, value: ControlHoldMonitor.syntheticEventMarker)
            textView.keyDown(with: NSEvent(cgEvent: syntheticEscape)!)
            check(cancelCount, 0, "marked synthetic voice Escape cannot cancel the composer")
        }

        do {
            let scrollView = NSScrollView(frame: .zero)
            let textView = NSTextView()
            textView.textContainerInset = NSSize(width: 12, height: 10)
            ComposerTextLayout.attach(textView, to: scrollView)
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .bezelBorder
            scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
            ComposerTextLayout.synchronize(textView, with: scrollView)
            check(textView.frame.width > 0, true, "composer text view has drawable width")
            check(
                textView.frame.width,
                scrollView.contentSize.width,
                "composer text view tracks scroll width"
            )
            check(
                (textView.textContainer?.containerSize.width ?? 0) > 0,
                true,
                "composer text container has drawable width"
            )
            check(
                textView.textContainer?.widthTracksTextView,
                true,
                "composer container tracks text view width"
            )
        }

        do {
            let domain = "DoubaoVoiceBridgeSelfTest.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: domain)!
            defaults.removePersistentDomain(forName: domain)
            defer { defaults.removePersistentDomain(forName: domain) }
            let store = ShortcutConfigurationStore(defaults: defaults)
            check(store.didCompleteSetup, false, "first run starts without a completed setup record")

            let controlShiftK = KeyboardShortcut(
                keyCode: 40,
                modifierMask: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
            )
            check(controlShiftK.validationError, nil, "ordinary modifier chords can be recorded")
            check(KeyboardShortcut(keyCode: 62).isModifierOnly, true, "right Control can be recorded alone")
            check(KeyboardShortcut(keyCode: 53).validationError != nil, true, "Escape remains reserved")
            check(
                KeyboardShortcut(keyCode: 63, modifierMask: CGEventFlags.maskCommand.rawValue).validationError != nil,
                true,
                "Fn cannot be combined with another modifier"
            )
            let expectedChordDown: [SyntheticKeyboardEventDescription] = [
                .init(kind: .flagsChanged, keyCode: 59, flags: CGEventFlags.maskControl.rawValue),
                .init(
                    kind: .flagsChanged,
                    keyCode: 56,
                    flags: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
                ),
                .init(
                    kind: .keyDown,
                    keyCode: 40,
                    flags: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
                )
            ]
            check(
                SyntheticKeyboardShortcutPlan.events(for: controlShiftK, down: true),
                expectedChordDown,
                "synthetic custom chord presses modifiers before its primary key"
            )
            let expectedChordUp: [SyntheticKeyboardEventDescription] = [
                .init(
                    kind: .keyUp,
                    keyCode: 40,
                    flags: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
                ),
                .init(kind: .flagsChanged, keyCode: 56, flags: CGEventFlags.maskControl.rawValue),
                .init(kind: .flagsChanged, keyCode: 59, flags: 0)
            ]
            check(
                SyntheticKeyboardShortcutPlan.events(for: controlShiftK, down: false),
                expectedChordUp,
                "synthetic custom chord releases its primary before balancing modifiers"
            )
            check(
                SyntheticKeyboardShortcutPlan.events(for: KeyboardShortcut(keyCode: 62), down: true),
                [.init(kind: .flagsChanged, keyCode: 62, flags: CGEventFlags.maskControl.rawValue)],
                "right Control uses its own modifier keycode"
            )

            let customDoubao = DoubaoShortcutConfiguration.manual(.leftControlHold, shortcut: controlShiftK)
            let remoteLeftControl = ShortcutProfile(doubao: customDoubao, bridge: .leftControlHold)
            check(remoteLeftControl.isSupported, true, "custom Doubao chord works with the independent left-Control bridge")
            check(remoteLeftControl.bridgeShortcut, .leftControl, "left-Control remote trigger remains independent of Doubao chord")
            let remoteCustom = ShortcutProfile(
                doubao: DoubaoShortcutConfiguration.manual(.leftControlHold, shortcut: KeyboardShortcut(keyCode: 62)),
                bridge: .customHold(KeyboardShortcut(keyCode: 40))
            )
            check(remoteCustom.isSupported, true, "right-Control Doubao hold works with a custom remote trigger")
            check(remoteCustom.bridgeShortcut, KeyboardShortcut(keyCode: 40), "custom remote binding is selected")
            let customReadiness = ShortcutTriggerReadiness.status(
                profile: remoteCustom,
                setupPending: false,
                monitorActive: true
            ) ?? ""
            check(
                customReadiness.contains(remoteCustom.bridgeShortcut.displayName) &&
                    customReadiness.contains(remoteCustom.doubao.keyboardShortcut.displayName),
                true,
                "custom status text names the configured remote and Doubao keys"
            )
            check(
                SessionCoordinator.shouldObserveControlRelease(manualEntry: false, profile: controlProfileForReleaseTest()),
                false,
                "a monitor-triggered session ignores unrelated local left-Control releases"
            )
            check(
                SessionCoordinator.shouldObserveControlRelease(manualEntry: false, profile: remoteCustom),
                false,
                "custom remote sessions never use the fixed left-Control composer release"
            )
            check(
                SessionCoordinator.shouldObserveControlRelease(manualEntry: true, profile: remoteCustom),
                false,
                "custom Doubao bindings cannot open an unfinished manual composer session"
            )
            check(
                ShortcutProfile(doubao: customDoubao, bridge: .followDoubao).isSupported,
                false,
                "custom Doubao key cannot silently become the remote toggle trigger"
            )

            let doubao = DoubaoShortcutConfiguration(
                mode: .fnToggle,
                source: .visibleSettingsWindow,
                observedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            check(
                store.save(confirmedDoubaoMode: .fnToggle, manualDoubaoMode: nil, bridge: .leftControlHold),
                true,
                "valid automatic profile writes and passes readback"
            )
            check(store.didCompleteSetup, true, "saving a valid profile completes setup")
            check(store.loadManualDoubaoConfiguration(), nil, "automatic confirmation does not become a manual override")
            check(store.loadLastConfirmedDoubaoConfiguration()?.mode, .fnToggle, "confirmed mode persists after automatic settings close")
            check(store.loadLastConfirmedDoubaoConfiguration()?.source, .confirmed, "persisted automatic mode is labeled as last confirmed")
            check(store.loadBridgeConfiguration()?.kind, .leftControlHold, "independent bridge shortcut persists")
            check(store.hasCorruptOrIncompleteSavedConfiguration, false, "complete valid setup is accepted")

            store.updateConfirmedModeFromAutomaticRead(.leftControlHold)
            check(store.loadLastConfirmedDoubaoConfiguration()?.mode, .leftControlHold, "automatic profile refresh changes the saved mode")
            check(store.loadBridgeConfiguration()?.kind, .leftControlHold, "automatic mode refresh preserves the independent bridge key")
            check(store.loadManualDoubaoConfiguration(), nil, "automatic refresh does not create a manual override")

            let customRemoteKey = KeyboardShortcut(keyCode: 40, modifierMask: CGEventFlags.maskCommand.rawValue)
            check(
                store.save(
                    confirmedDoubaoMode: .leftControlHold,
                    manualDoubaoMode: .leftControlHold,
                    manualDoubaoShortcut: controlShiftK,
                    confirmedDoubaoShortcut: controlShiftK,
                    bridge: .customHold(customRemoteKey)
                ),
                true,
                "custom Doubao and remote bindings persist with readback validation"
            )
            check(store.loadManualDoubaoConfiguration()?.keyboardShortcut, controlShiftK, "manual Doubao chord reads back intact")
            check(store.loadLastConfirmedDoubaoConfiguration()?.keyboardShortcut, controlShiftK, "confirmed Doubao chord reads back intact")
            check(store.loadBridgeConfiguration()?.shortcut, customRemoteKey, "custom remote shortcut reads back intact")
            check(store.hasCorruptOrIncompleteSavedConfiguration, false, "complete custom configuration is accepted")

            let confirmedDomain = "DoubaoVoiceBridgeConfirmedCustomSelfTest.\(UUID().uuidString)"
            let confirmedDefaults = UserDefaults(suiteName: confirmedDomain)!
            confirmedDefaults.removePersistentDomain(forName: confirmedDomain)
            defer { confirmedDefaults.removePersistentDomain(forName: confirmedDomain) }
            let confirmedStore = ShortcutConfigurationStore(defaults: confirmedDefaults)
            let customDoubaoKey = KeyboardShortcut(
                keyCode: 40,
                modifierMask: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
            )
            let remoteKey = KeyboardShortcut(keyCode: 97)
            check(
                confirmedStore.save(
                    confirmedDoubaoMode: .leftControlHold,
                    manualDoubaoMode: .leftControlHold,
                    manualDoubaoShortcut: customDoubaoKey,
                    confirmedDoubaoShortcut: customDoubaoKey,
                    bridge: .customHold(remoteKey)
                ),
                true,
                "choosing a confirmed custom Doubao key preserves it as an explicit override"
            )
            confirmedStore.updateConfirmedModeFromAutomaticRead(.fnToggle)
            check(
                confirmedStore.loadLastConfirmedDoubaoConfiguration()?.keyboardShortcut,
                customDoubaoKey,
                "a later automatic legacy read cannot replace the explicitly selected confirmed custom key"
            )
            let resolvedCustom = confirmedStore.loadManualDoubaoConfiguration() ??
                confirmedStore.loadLastConfirmedDoubaoConfiguration()
            check(
                resolvedCustom?.keyboardShortcut,
                customDoubaoKey,
                "store-to-refresh resolution keeps the custom voice key active across automatic refresh"
            )

            store.updateConfirmedModeFromAutomaticRead(.fnToggle)
            check(store.loadLastConfirmedDoubaoConfiguration()?.mode, .leftControlHold, "automatic legacy reads cannot override an explicitly selected custom shortcut")
            check(store.loadBridgeConfiguration()?.kind, .customHold, "automatic reads preserve an explicitly selected custom remote key")
            check(store.loadManualDoubaoConfiguration()?.keyboardShortcut, controlShiftK, "explicit custom voice key remains a manual override")

            defaults.set("unknown-v99", forKey: "shortcut.manualDoubaoMode.v1")
            check(store.loadManualDoubaoConfiguration(), nil, "unknown manual profile is not interpreted")
            check(store.hasCorruptOrIncompleteSavedConfiguration, true, "corrupt saved profile requires setup again")

            let followProfile = ShortcutProfile(doubao: doubao, bridge: .followDoubao)
            check(followProfile.usesFnBridge, true, "follow mode uses the confirmed Fn trigger")
            check(followProfile.usesLeftControlBridge, false, "follow Fn mode does not also capture Control")
            let independentProfile = ShortcutProfile(doubao: doubao, bridge: .leftControlHold)
            check(independentProfile.usesFnBridge, false, "independent Control bridge does not intercept physical Fn")
            check(independentProfile.usesLeftControlBridge, true, "independent bridge captures left Control")
            check(independentProfile.isSupported, true, "Fn Doubao with Control bridge is a supported profile")
            check(followProfile.supportsManualComposerEntry, false, "Fn-follow profile cannot open an unfinishable manual session")
            check(independentProfile.supportsManualComposerEntry, false, "independent Control-to-Fn profile cannot bypass its trigger lifecycle")

            let controlProfile = ShortcutProfile(
                doubao: DoubaoShortcutConfiguration(mode: .leftControlHold, source: .manual, observedAt: Date()),
                bridge: .followDoubao
            )
            check(controlProfile.supportsManualComposerEntry, true, "left Control profile keeps manual composer entry")
            let refreshedControlProfile = ShortcutProfile(
                doubao: DoubaoShortcutConfiguration(
                    mode: .leftControlHold,
                    source: .preferences("test"),
                    observedAt: Date()
                ),
                bridge: .followDoubao
            )
            check(
                ShortcutProfile.hasSameTriggerBehavior(controlProfile, refreshedControlProfile),
                true,
                "a source-only refresh does not count as a shortcut behavior change"
            )
            check(
                ShortcutTriggerReadiness.status(profile: controlProfile, setupPending: false, monitorActive: false),
                nil,
                "readiness is unavailable before the event tap starts"
            )
            check(
                ShortcutTriggerReadiness.status(profile: controlProfile, setupPending: true, monitorActive: true),
                nil,
                "a supported profile is not ready while setup remains pending"
            )
            check(
                ShortcutTriggerReadiness.status(profile: controlProfile, setupPending: false, monitorActive: true),
                "就绪 · 按住 Left ⌃ 开始，松开结束；豆包：长按左 ⌃ 说话，松开自动发送",
                "readiness is published only for a supported profile with an active event tap"
            )

            let unsupportedProfile = ShortcutProfile(
                doubao: DoubaoShortcutConfiguration(mode: .disabled, source: .manual, observedAt: Date()),
                bridge: .followDoubao
            )
            check(unsupportedProfile.supportsManualComposerEntry, false, "disabled profiles cannot enter manual composer")

            let coordinator = SessionCoordinator()
            var statusChanges: [String] = []
            coordinator.onStatusChange = { text, _ in statusChanges.append(text) }
            coordinator.updateShortcutProfile(controlProfile)
            coordinator.updateShortcutProfile(refreshedControlProfile)
            check(
                statusChanges,
                [],
                "repeated profile refresh does not publish readiness over an existing error status"
            )

            let syntheticFnDownFlags = SyntheticShortcutEventFlags.fnToggle(down: true)
            check(syntheticFnDownFlags.contains(.maskSecondaryFn), true, "synthetic Doubao Fn down carries Fn")
            check(syntheticFnDownFlags.contains(.maskControl), false, "synthetic Doubao Fn does not inherit physical bridge Control")
            check(SyntheticShortcutEventFlags.fnToggle(down: false), [], "synthetic Doubao Fn up clears all modifiers")
        }

        do {
            let controlShiftChord = KeyboardShortcut(
                keyCode: 40,
                modifierMask: CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue
            )
            let controlK = KeyboardShortcut(keyCode: 40, modifierMask: CGEventFlags.maskControl.rawValue)

            let mismatch = ControlMonitorEventHarness(shortcut: controlK)
            check(mismatch.sendModifier(59, flags: .maskControl), true, "custom chord buffers its Control prefix")
            check(mismatch.sendKey(1, down: true, flags: .maskControl), false, "a nonmatching key replays the native prefix and passes through")
            check(
                mismatch.replayed.map(\.summary),
                [.init(type: .flagsChanged, keyCode: 59, flags: CGEventFlags.maskControl.rawValue)],
                "custom chord mismatch replays only the original modifier prefix"
            )
            mismatch.monitor.stop()

            let quickModifierRelease = ControlMonitorEventHarness(shortcut: controlK)
            _ = quickModifierRelease.sendModifier(59, flags: .maskControl)
            _ = quickModifierRelease.sendKey(40, down: true, flags: .maskControl)
            check(quickModifierRelease.sendModifier(59, flags: []), true, "quick custom hold consumes its matching modifier release")
            check(
                quickModifierRelease.replayed.map(\.summary),
                [
                    .init(type: .flagsChanged, keyCode: 59, flags: CGEventFlags.maskControl.rawValue),
                    .init(type: .keyDown, keyCode: 40, flags: CGEventFlags.maskControl.rawValue),
                    .init(type: .flagsChanged, keyCode: 59, flags: 0)
                ],
                "quick custom modifier release replays the complete down/down/up sequence in order"
            )
            quickModifierRelease.monitor.stop()

            let quickPrimaryRelease = ControlMonitorEventHarness(shortcut: controlK)
            _ = quickPrimaryRelease.sendModifier(59, flags: .maskControl)
            _ = quickPrimaryRelease.sendKey(40, down: true, flags: .maskControl)
            check(quickPrimaryRelease.sendKey(40, down: false, flags: .maskControl), true, "quick custom primary release is consumed")
            check(
                quickPrimaryRelease.replayed.map(\.summary),
                [
                    .init(type: .flagsChanged, keyCode: 59, flags: CGEventFlags.maskControl.rawValue),
                    .init(type: .keyDown, keyCode: 40, flags: CGEventFlags.maskControl.rawValue),
                    .init(type: .keyUp, keyCode: 40, flags: CGEventFlags.maskControl.rawValue)
                ],
                "quick custom primary release balances the buffered trigger without losing native typing"
            )
            quickPrimaryRelease.monitor.stop()

            let neutralized = ControlMonitorEventHarness(shortcut: controlK)
            _ = neutralized.sendModifier(59, flags: .maskControl)
            _ = neutralized.sendKey(40, down: true, flags: .maskControl)
            neutralized.monitor.activateDictationIfStillPending()
            check(neutralized.beginCount, 1, "custom trigger reaches the production long-press activation path")
            check(neutralized.sendModifier(56, flags: [.maskControl, .maskShift]), true, "extra Shift is reposted without the swallowed Control mask")
            check(
                neutralized.replayed.last?.summary,
                .init(type: .flagsChanged, keyCode: 56, flags: CGEventFlags.maskShift.rawValue),
                "custom hold strips swallowed Control from a later modifier event"
            )
            check(neutralized.sendMouseDown(flags: [.maskControl, .maskShift]), true, "mouse input is reposted without the swallowed Control mask")
            check(
                neutralized.replayed.last?.summary,
                .init(type: .leftMouseDown, keyCode: 0, flags: CGEventFlags.maskShift.rawValue),
                "custom hold strips swallowed Control from mouse events too"
            )
            neutralized.monitor.stop()

            let lostFocus = ControlMonitorEventHarness(shortcut: controlK)
            _ = lostFocus.sendModifier(59, flags: .maskControl)
            lostFocus.windowMatches = false
            check(lostFocus.sendKey(40, down: true, flags: .maskControl), true, "focus loss drops a buffered prefix instead of replaying into another app")
            check(
                lostFocus.replayed.last?.summary,
                .init(type: .keyDown, keyCode: 40, flags: 0),
                "focus loss removes the buffered Control mask from later key events"
            )
            check(lostFocus.sendModifier(59, flags: []), true, "orphaned Control release remains consumed after focus loss")
            check(lostFocus.monitor.isGestureIdle, true, "focus-lost modifier state clears when its physical release arrives")
            lostFocus.monitor.stop()

            let changedTargetAtThreshold = ControlMonitorEventHarness(shortcut: controlK)
            _ = changedTargetAtThreshold.sendModifier(59, flags: .maskControl)
            _ = changedTargetAtThreshold.sendKey(40, down: true, flags: .maskControl)
            changedTargetAtThreshold.windowMatches = false
            changedTargetAtThreshold.monitor.activateDictationIfStillPending()
            check(changedTargetAtThreshold.beginCount, 0, "custom long-press cancels when the captured UU window changes before threshold")
            check(changedTargetAtThreshold.captureCount, 1, "custom threshold never recaptures a newly focused window")
            check(changedTargetAtThreshold.monitor.isGestureIdle, false, "changed target keeps consumed modifiers neutralized until release")
            _ = changedTargetAtThreshold.sendKey(40, down: false, flags: .maskControl)
            _ = changedTargetAtThreshold.sendModifier(59, flags: [])
            check(changedTargetAtThreshold.monitor.isGestureIdle, true, "changed-target modifier state clears after physical releases")
            changedTargetAtThreshold.monitor.stop()

            let fnCompanion = ControlMonitorEventHarness(shortcut: .fn)
            check(fnCompanion.sendModifier(63, flags: .maskSecondaryFn), true, "custom Fn trigger begins from the physical Fn flags event")
            check(fnCompanion.sendKey(179, down: true, flags: .maskSecondaryFn, sourcePID: 0), true, "Fn companion key 179 is suppressed by the custom trigger path")
            check(fnCompanion.monitor.isGestureIdle, false, "Fn companion does not abort the pending custom Fn trigger")
            fnCompanion.monitor.activateDictationIfStillPending()
            check(fnCompanion.beginCount, 1, "custom Fn survives its companion event and reaches activation")
            fnCompanion.monitor.stop()

            let fnChord = ControlMonitorEventHarness(shortcut: .fn)
            _ = fnChord.sendModifier(63, flags: .maskSecondaryFn)
            check(
                fnChord.sendModifier(59, flags: [.maskSecondaryFn, .maskControl]),
                false,
                "Fn plus Control aborts the custom Fn trigger and remains a native chord"
            )
            check(fnChord.beginCount, 0, "Fn plus Control cannot reach custom trigger activation")
            check(
                fnChord.sendKey(179, down: true, flags: [.maskSecondaryFn, .maskControl], sourcePID: 0),
                false,
                "aborted Fn chord disarms companion suppression so key 179 stays native"
            )
            fnChord.monitor.stop()

            let functionKey = ControlMonitorEventHarness(shortcut: KeyboardShortcut(keyCode: 97))
            check(functionKey.sendKey(97, down: true, flags: .maskSecondaryFn), true, "F6 keydown flag does not masquerade as a physical Fn chord")
            check(functionKey.monitor.isGestureIdle, false, "F6 remains a usable custom remote trigger")
            functionKey.monitor.stop()

            let physicalFnChord = ControlMonitorEventHarness(shortcut: KeyboardShortcut(keyCode: 97))
            _ = physicalFnChord.sendModifier(63, flags: .maskSecondaryFn)
            check(physicalFnChord.sendKey(97, down: true, flags: .maskSecondaryFn), false, "actual physical Fn plus F6 is passed through as a chord")
            check(physicalFnChord.beginCount, 0, "actual Fn plus another key cannot start a custom F6 trigger")
            physicalFnChord.monitor.stop()

            let cancelled = ControlMonitorEventHarness(shortcut: controlK)
            _ = cancelled.sendModifier(59, flags: .maskControl)
            _ = cancelled.sendKey(40, down: true, flags: .maskControl)
            let escape = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )!
            cancelled.monitor.cancelActiveSession(event: ComposerInputEventMetadata(event: escape))
            check(cancelled.replayed, [], "Escape cancellation discards a buffered shortcut without replaying it")
            _ = cancelled.sendKey(40, down: false, flags: .maskControl)
            _ = cancelled.sendModifier(59, flags: [])
            check(cancelled.monitor.isGestureIdle, true, "cancelled custom keys drain their releases and return to idle")
            cancelled.monitor.stop()

            let tapInterrupted = ControlMonitorEventHarness(shortcut: controlK)
            _ = tapInterrupted.sendModifier(59, flags: .maskControl)
            let disabledEvent = CGEvent(source: tapInterrupted.source)!
            _ = tapInterrupted.monitor.processEventForTesting(type: .tapDisabledByTimeout, event: disabledEvent)
            check(tapInterrupted.monitor.isGestureIdle, false, "tap interruption retains an orphan mask until a physical release")
            tapInterrupted.monitor.stop()
            check(tapInterrupted.monitor.isGestureIdle, true, "stopping after tap interruption clears all custom interception state")

            check(controlShiftChord.validationError, nil, "event-level chord cases use a valid configurable shortcut")
        }

        if failures.isEmpty {
            print("SELF_TEST_OK")
            return true
        }
        for failure in failures {
            fputs("SELF_TEST_FAILURE \(failure)\n", stderr)
        }
        return false
    }

    private static func controlProfileForReleaseTest() -> ShortcutProfile {
        ShortcutProfile(
            doubao: DoubaoShortcutConfiguration(
                mode: .leftControlHold,
                source: .manual,
                observedAt: Date()
            ),
            bridge: .followDoubao
        )
    }
}

private final class ControlMonitorEventHarness {
    struct Summary: Equatable {
        let type: CGEventType
        let keyCode: Int64
        let flags: UInt64
    }

    struct RecordedEvent: Equatable {
        let summary: Summary
    }

    let source = CGEventSource(stateID: .combinedSessionState)!
    let target = UURemoteTarget(application: NSRunningApplication.current)
    let profile: ShortcutProfile
    var windowMatches = true
    var captureCount = 0
    var beginCount = 0
    var replayed: [RecordedEvent] = []

    lazy var monitor: ControlHoldMonitor = {
        ControlHoldMonitor(
            profile: profile,
            holdThreshold: 0.25,
            targetProvider: { self.target },
            targetProviderDiagnostic: { "self-test" },
            targetIsActive: { _ in true },
            localComposerReady: { false },
            onBegin: { _, _ in self.beginCount += 1 },
            onFnToggleMayBeActive: {},
            onRelease: {},
            onCancel: {},
            customTargetWindowMatches: { _ in self.windowMatches },
            customTargetWindowCapture: { _ in self.captureCount += 1; return true },
            customEventReplay: { _, event in
                self.replayed.append(RecordedEvent(summary: Summary(
                    type: event.type,
                    keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                    flags: event.flags.rawValue
                )))
            },
            syntheticKeyboardEventPoster: { _, _ in true },
            bridgeApplicationOwnsFocus: { true }
        )
    }()

    init(shortcut: KeyboardShortcut) {
        profile = ShortcutProfile(
            doubao: DoubaoShortcutConfiguration(mode: .leftControlHold, source: .manual, observedAt: Date()),
            bridge: .customHold(shortcut)
        )
    }

    @discardableResult
    func sendModifier(_ keyCode: Int64, flags: CGEventFlags) -> Bool {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)!
        event.type = .flagsChanged
        event.flags = flags
        return monitor.processEventForTesting(type: .flagsChanged, event: event)
    }

    @discardableResult
    func sendKey(_ keyCode: Int64, down: Bool, flags: CGEventFlags, sourcePID: Int64? = nil) -> Bool {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)!
        event.flags = flags
        if let sourcePID { event.setIntegerValueField(.eventSourceUnixProcessID, value: sourcePID) }
        let type: CGEventType = down ? .keyDown : .keyUp
        return monitor.processEventForTesting(type: type, event: event)
    }

    @discardableResult
    func sendMouseDown(flags: CGEventFlags) -> Bool {
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .left
        )!
        event.flags = flags
        return monitor.processEventForTesting(type: .leftMouseDown, event: event)
    }
}
