import AppKit
import SwiftUI

/// What macOS itself does when the Fn (🌐) key is pressed, from the user's
/// keyboard settings. Speaker only reads it to explain a conflict with the Fn
/// shortcut; changing it stays the user's decision in System Settings.
package enum FunctionKeySystemAction: Equatable, Sendable {
    case doNothing
    case changeInputSource
    case showEmojiAndSymbols
    case startDictation
    /// No stored choice; macOS applies its own default, which acts on the key.
    case systemDefault

    package static let keyboardSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
    )!

    package init(storedValue: Int?) {
        switch storedValue {
        case 0: self = .doNothing
        case 1: self = .changeInputSource
        case 2: self = .showEmojiAndSymbols
        case 3: self = .startDictation
        default: self = .systemDefault
        }
    }

    /// Reads `AppleFnUsageType` from the HIToolbox preferences domain.
    package static func current() -> FunctionKeySystemAction {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain)
        return FunctionKeySystemAction(storedValue: (value as? NSNumber)?.intValue)
    }

    /// Why pressing Fn may also trigger macOS, or `nil` when it does nothing.
    package var conflictMessage: String? {
        let effect: String
        switch self {
        case .doNothing: return nil
        case .changeInputSource: effect = "还会更改输入法"
        case .showEmojiAndSymbols: effect = "还会显示表情与符号"
        case .startDictation: effect = "连按两下还会开始 macOS 听写"
        case .systemDefault: effect = "可能还会更改输入法或显示表情"
        }
        return "按 Fn（🌐）键时，macOS \(effect)。可在键盘设置中把「按下 🌐 键时」改为「不执行任何操作」。"
    }
}

/// A notice beside the Fn shortcut that appears only while macOS also acts on
/// the key. It re-reads the setting whenever Speaker becomes active, so it
/// disappears after the user changes it in System Settings.
struct FunctionKeyConflictHint: View {
    @State private var action = FunctionKeySystemAction.current()
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let message = action.conflictMessage {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "globe")
                        .foregroundStyle(SpeakerTone.warning.color)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(SpeakerTypography.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("打开键盘设置") {
                        openURL(FunctionKeySystemAction.keyboardSettingsURL)
                    }
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            action = FunctionKeySystemAction.current()
        }
    }
}
