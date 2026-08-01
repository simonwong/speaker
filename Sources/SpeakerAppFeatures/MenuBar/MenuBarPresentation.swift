import SpeakerCore

package enum MenuBarIconState: Equatable, Sendable {
    case ready
    case recording
    case needsPermission
}

package enum MenuBarRow: Equatable, Sendable {
    case openSpeaker
    case refinementMode
    case voiceStatus
    case cancelVoiceInput
    case voiceNotice
    case copyRetainedText
    case recoverVoiceInput
    case dismissVoiceInput
    case settings
    case dataErasureStatus
    case dataErasureRecovery
    case quit
    case divider
}

package struct MenuBarVoiceCapabilities: Equatable, Sendable {
    package let showsStatus: Bool
    package let showsNotice: Bool
    package let canCancel: Bool
    package let canCopyRetainedText: Bool
    package let canRecover: Bool
    package let canDismiss: Bool

    package init(
        showsStatus: Bool = false,
        showsNotice: Bool = false,
        canCancel: Bool = false,
        canCopyRetainedText: Bool = false,
        canRecover: Bool = false,
        canDismiss: Bool = false
    ) {
        self.showsStatus = showsStatus
        self.showsNotice = showsNotice
        self.canCancel = canCancel
        self.canCopyRetainedText = canCopyRetainedText
        self.canRecover = canRecover
        self.canDismiss = canDismiss
    }

    package init(menu: VoiceInputMenuPresentation) {
        self.init(
            showsStatus: menu.status != nil,
            showsNotice: menu.notice != nil,
            canCancel: menu.cancelAction != nil,
            canCopyRetainedText: menu.copyRetainedTextAction != nil,
            canRecover: menu.recoveryAction != nil,
            canDismiss: menu.dismissAction != nil
        )
    }
}

package enum MenuBarPresentation {
    package static func iconState(
        isRecording: Bool,
        permissions: PermissionSnapshot
    ) -> MenuBarIconState {
        if isRecording {
            return .recording
        }
        return permissions.allGranted
            ? .ready
            : .needsPermission
    }

    package static func rows(
        voice: MenuBarVoiceCapabilities,
        workspaceRoute: DataErasureWorkspaceRoute
    ) -> [MenuBarRow] {
        guard workspaceRoute == .normal else {
            return rows(in: [
                [.dataErasureStatus, .dataErasureRecovery],
                [.quit],
            ])
        }

        var voiceRows: [MenuBarRow] = []
        if voice.showsStatus { voiceRows.append(.voiceStatus) }
        if voice.canCancel { voiceRows.append(.cancelVoiceInput) }
        if voice.showsNotice { voiceRows.append(.voiceNotice) }
        if voice.canCopyRetainedText { voiceRows.append(.copyRetainedText) }
        if voice.canRecover { voiceRows.append(.recoverVoiceInput) }
        if voice.canDismiss { voiceRows.append(.dismissVoiceInput) }

        return rows(in: [
            [.openSpeaker, .refinementMode],
            voiceRows,
            [.settings],
            [.quit],
        ])
    }

    private static func rows(in groups: [[MenuBarRow]]) -> [MenuBarRow] {
        groups.filter { !$0.isEmpty }.reduce(into: []) { rows, group in
            if !rows.isEmpty { rows.append(.divider) }
            rows.append(contentsOf: group)
        }
    }
}
