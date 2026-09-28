import SpeakerCore
import SwiftUI

/// The single mapping from a permission state to its badge.
///
/// The settings page and the onboarding window both badge the same state, so
/// they read the same text, SF Symbol and tint from here. A granted
/// permission gets a muted green circle and quiet text; the icon tile beside it
/// stays plain, because only states that need action colour the tile.
package struct PermissionStatusPresentation: Equatable, Sendable {
    package let text: String
    package let symbolName: String
    package let tint: Color

    package init(state: PermissionState) {
        switch state {
        case .granted:
            text = "已开启"
            symbolName = "checkmark.circle.fill"
            tint = SpeakerVisualIdentity.settledGreen
        case .denied:
            text = "未开启"
            symbolName = "exclamationmark.circle.fill"
            tint = .orange
        case .notDetermined:
            text = "待允许"
            symbolName = "exclamationmark.circle.fill"
            tint = .orange
        case .restricted:
            text = "受系统限制"
            symbolName = "lock.circle.fill"
            tint = .red
        }
    }

    /// The icon tile beside the badge: plain when nothing needs attention.
    package var tileTint: Color? { StatusBadge.isSettled(tint) ? nil : tint }
}
