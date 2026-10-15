import AppKit
import Foundation

enum SyntheticShortcutEventFlags {
    static func fnToggle(down: Bool) -> CGEventFlags {
        down ? [.maskSecondaryFn] : []
    }
}

enum BridgeShortcutKind: String, CaseIterable {
    case followDoubao
    case leftControlHold

    var title: String {
        switch self {
        case .followDoubao: return "跟随豆包按键"
        case .leftControlHold: return "左 Control 长按"
        }
    }
}

struct BridgeShortcutConfiguration: Equatable {
    let kind: BridgeShortcutKind

    static let followDoubao = BridgeShortcutConfiguration(kind: .followDoubao)
    static let leftControlHold = BridgeShortcutConfiguration(kind: .leftControlHold)

    var display: String {
        switch kind {
        case .followDoubao: return "跟随豆包按键"
        case .leftControlHold: return "左 Control 长按"
        }
    }

    func validationError(for doubao: DoubaoShortcutConfiguration) -> String? {
        guard doubao.mode.isSupported else { return "请先选择豆包支持的语音按键与开始方式" }
        return nil
    }
}

struct ShortcutProfile: Equatable {
    let doubao: DoubaoShortcutConfiguration
    let bridge: BridgeShortcutConfiguration

    var isSupported: Bool {
        doubao.mode.isSupported && bridge.validationError(for: doubao) == nil
    }

    var usesFnBridge: Bool {
        bridge.kind == .followDoubao && doubao.mode == .fnToggle
    }

    var usesLeftControlBridge: Bool {
        bridge.kind == .leftControlHold ||
            (bridge.kind == .followDoubao && doubao.mode == .leftControlHold)
    }

    var supportsManualComposerEntry: Bool {
        isSupported && doubao.mode == .leftControlHold
    }

    var bridgeInstruction: String {
        if usesFnBridge { return "按 Fn 开始，再按任意键结束" }
        return "长按左 Control 开始，松开结束"
    }

    var doubaoInstruction: String { doubao.mode.instruction }

    static func hasSameTriggerBehavior(_ first: ShortcutProfile?, _ second: ShortcutProfile?) -> Bool {
        guard let first, let second else { return first == nil && second == nil }
        return first.doubao.mode == second.doubao.mode && first.bridge.kind == second.bridge.kind
    }
}

enum ShortcutTriggerReadiness {
    static func status(
        profile: ShortcutProfile?,
        setupPending: Bool,
        monitorActive: Bool
    ) -> String? {
        guard !setupPending, monitorActive,
              let profile, profile.isSupported else { return nil }
        return "就绪 · \(profile.bridgeInstruction)；豆包：\(profile.doubaoInstruction)"
    }
}

struct ShortcutConfigurationStore {
    private let defaults: UserDefaults
    private let manualDoubaoKey = "shortcut.manualDoubaoMode.v1"
    private let confirmedDoubaoKey = "shortcut.confirmedDoubaoMode.v1"
    private let confirmedAtKey = "shortcut.confirmedAt.v1"
    private let bridgeKindKey = "shortcut.bridgeKind.v1"
    private let setupCompleteKey = "shortcut.setupComplete.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var didCompleteSetup: Bool { defaults.bool(forKey: setupCompleteKey) }

    var hasCorruptOrIncompleteSavedConfiguration: Bool {
        guard didCompleteSetup else { return false }
        let manualWasSaved = defaults.object(forKey: manualDoubaoKey) != nil
        let bridgeWasSaved = defaults.object(forKey: bridgeKindKey) != nil
        let confirmedAt = (defaults.object(forKey: confirmedAtKey) as? NSNumber)?.doubleValue ?? 0
        let manualAndConfirmedModesMatch = loadManualDoubaoConfiguration()?.mode == nil ||
            loadManualDoubaoConfiguration()?.mode == loadLastConfirmedDoubaoConfiguration()?.mode
        return (manualWasSaved && loadManualDoubaoConfiguration() == nil) ||
            !bridgeWasSaved || loadBridgeConfiguration() == nil ||
            loadLastConfirmedDoubaoConfiguration() == nil || confirmedAt <= 0 ||
            !manualAndConfirmedModesMatch
    }

    func loadManualDoubaoConfiguration() -> DoubaoShortcutConfiguration? {
        guard let raw = defaults.string(forKey: manualDoubaoKey) else { return nil }
        let mode: DoubaoShortcutMode
        switch raw {
        case "fnToggle": mode = .fnToggle
        case "leftControlHold": mode = .leftControlHold
        default: return nil
        }
        return DoubaoShortcutConfiguration(mode: mode, source: .manual, observedAt: Date())
    }

    func loadBridgeConfiguration() -> BridgeShortcutConfiguration? {
        guard let raw = defaults.string(forKey: bridgeKindKey),
              let kind = BridgeShortcutKind(rawValue: raw) else { return nil }
        return BridgeShortcutConfiguration(kind: kind)
    }

    func loadLastConfirmedDoubaoConfiguration() -> DoubaoShortcutConfiguration? {
        guard let raw = defaults.string(forKey: confirmedDoubaoKey),
              let mode = supportedMode(from: raw) else { return nil }
        let timestamp = defaults.double(forKey: confirmedAtKey)
        let observedAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : Date()
        return DoubaoShortcutConfiguration(mode: mode, source: .confirmed, observedAt: observedAt)
    }

    func updateConfirmedModeFromAutomaticRead(_ mode: DoubaoShortcutMode) {
        guard didCompleteSetup,
              defaults.object(forKey: manualDoubaoKey) == nil,
              !hasCorruptOrIncompleteSavedConfiguration,
              let raw = rawValue(for: mode) else { return }
        guard loadLastConfirmedDoubaoConfiguration()?.mode != mode else { return }
        defaults.set(raw, forKey: confirmedDoubaoKey)
        defaults.set(Date().timeIntervalSince1970, forKey: confirmedAtKey)
    }

    func save(
        confirmedDoubaoMode: DoubaoShortcutMode,
        manualDoubaoMode: DoubaoShortcutMode?,
        bridge: BridgeShortcutConfiguration
    ) -> Bool {
        guard let confirmedRaw = rawValue(for: confirmedDoubaoMode) else { return false }
        defaults.set(confirmedRaw, forKey: confirmedDoubaoKey)
        defaults.set(Date().timeIntervalSince1970, forKey: confirmedAtKey)
        if let manualDoubaoMode {
            if let raw = rawValue(for: manualDoubaoMode) {
                defaults.set(raw, forKey: manualDoubaoKey)
            } else {
                defaults.removeObject(forKey: manualDoubaoKey)
            }
        } else {
            defaults.removeObject(forKey: manualDoubaoKey)
        }
        defaults.set(bridge.kind.rawValue, forKey: bridgeKindKey)
        defaults.set(true, forKey: setupCompleteKey)

        guard didCompleteSetup,
              loadLastConfirmedDoubaoConfiguration()?.mode == confirmedDoubaoMode,
              loadBridgeConfiguration()?.kind == bridge.kind else { return false }
        if let manualDoubaoMode {
            return loadManualDoubaoConfiguration()?.mode == manualDoubaoMode
        }
        return loadManualDoubaoConfiguration() == nil
    }

    private func supportedMode(from raw: String) -> DoubaoShortcutMode? {
        switch raw {
        case "fnToggle": return .fnToggle
        case "leftControlHold": return .leftControlHold
        default: return nil
        }
    }

    private func rawValue(for mode: DoubaoShortcutMode) -> String? {
        switch mode {
        case .fnToggle: return "fnToggle"
        case .leftControlHold: return "leftControlHold"
        case .disabled, .unsupported: return nil
        }
    }
}
