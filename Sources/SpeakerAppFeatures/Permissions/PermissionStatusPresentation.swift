import SpeakerCore
import SwiftUI

/// The single mapping from a permission state to its badge.
///
/// The settings page and the onboarding window both badge the same state, so
/// they read the same text, SF Symbol and tint from here.
package struct PermissionStatusPresentation: Equatable, Sendable {
    package let text: String
    package let symbolName: String
    package let tint: Color

    package init(state: PermissionState) {
        switch state {
        case .granted:
            text = "已开启"
            symbolName = "checkmark"
            tint = .green
        case .denied:
            text = "未开启"
            symbolName = "exclamationmark"
            tint = .orange
        case .notDetermined:
            text = "待允许"
            symbolName = "exclamationmark"
            tint = .orange
        case .restricted:
            text = "受系统限制"
            symbolName = "lock.fill"
            tint = .red
        }
    }
}
