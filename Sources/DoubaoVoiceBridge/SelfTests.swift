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
            check(store.loadLastConfirmedDoubaoConfiguration()?.mode, .leftControlHold, "supported automatic mode changes refresh the saved snapshot")
            check(store.loadBridgeConfiguration()?.kind, .leftControlHold, "automatic Doubao change preserves the independent bridge key")
            check(store.loadManualDoubaoConfiguration(), nil, "automatic refresh does not create a manual override")

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
                "就绪 · 长按左 Control 开始，松开结束；豆包：长按左 ⌃ 说话，松开自动发送",
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

        if failures.isEmpty {
            print("SELF_TEST_OK tests=13")
            return true
        }
        for failure in failures {
            fputs("SELF_TEST_FAILURE \(failure)\n", stderr)
        }
        return false
    }
}
