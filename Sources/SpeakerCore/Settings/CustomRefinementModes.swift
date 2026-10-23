import Foundation

/// One Custom Mode in the user's ordered list. The identifier keeps the
/// selection and later edits attached to the same mode across renames and
/// reordering; it is a local settings key and never leaves the Mac.
public struct CustomRefinementMode: Equatable, Hashable, Sendable, Codable, Identifiable {
    /// How many Custom Modes Settings keeps.
    public static let maximumCount = 10

    /// Identifiers given to Custom Modes migrated from settings written
    /// before the list existed. They are fixed so that every load of an
    /// unmigrated file names the same modes.
    static let legacySavedID = UUID(uuidString: "5A1E5A1E-0000-4000-8000-000000000001")!
    static let legacyActiveID = UUID(uuidString: "5A1E5A1E-0000-4000-8000-000000000002")!

    public let id: UUID
    public var name: String
    public var prompt: String

    public init(id: UUID = UUID(), name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }

    public var textRefinementMode: TextRefinementMode {
        .custom(name: name, prompt: prompt)
    }

    /// The mode with its name and prompt trimmed, or the validation error
    /// `TextRefinementMode` reports for them.
    public func validated() throws -> CustomRefinementMode {
        guard case .custom(let name, let prompt) = try textRefinementMode.validated() else {
            throw TextRefinementModeValidationError.emptyCustomPrompt
        }
        return CustomRefinementMode(id: id, name: name, prompt: prompt)
    }

    fileprivate func hasSameContent(as other: CustomRefinementMode) -> Bool {
        textRefinementMode.normalizedContent == other.textRefinementMode.normalizedContent
    }
}

extension TextRefinementMode {
    fileprivate var normalizedContent: TextRefinementMode {
        (try? validated()) ?? self
    }
}

/// One entry of the Refinement Mode list the user chooses from: a built-in
/// mode or one Custom Mode. The order of `RefinementModeSelection.order` is
/// the order the menu lists modes and the order the mode shortcut steps
/// through them.
public enum RefinementModeSelection: Equatable, Hashable, Sendable {
    case defaultSmooth
    case conciseCleanup
    case fullRewrite
    case custom(UUID)

    public static let builtIn: [RefinementModeSelection] = [
        .defaultSmooth, .conciseCleanup, .fullRewrite,
    ]

    /// Built-in modes first, then the Custom Modes in list order.
    public static func order(
        customModes: [CustomRefinementMode]
    ) -> [RefinementModeSelection] {
        builtIn + customModes.map { .custom($0.id) }
    }

    package var builtInMode: BuiltInRefinementMode? {
        switch self {
        case .conciseCleanup: .conciseCleanup
        case .fullRewrite: .fullRewrite
        case .defaultSmooth, .custom: nil
        }
    }

    public var customModeID: UUID? {
        if case .custom(let id) = self { id } else { nil }
    }

    /// The executable mode for this entry, or nil when it names a Custom
    /// Mode that is not in `customModes`.
    public func refinementMode(
        customModes: [CustomRefinementMode],
        promptOverrides: RefinementPromptOverrides
    ) -> TextRefinementMode? {
        if let builtInMode {
            return builtInMode.refinementMode(promptOverride: promptOverrides[builtInMode])
        }
        guard case .custom(let id) = self else { return .defaultSmooth }
        return customModes.first { $0.id == id }?.textRefinementMode
    }
}

extension RefinementPreference {
    /// The preference that selects `selection`, or nil for a Custom Mode
    /// that is not in `customModes`.
    public init?(selection: RefinementModeSelection, customModes: [CustomRefinementMode]) {
        switch selection {
        case .defaultSmooth: self = .defaultSmooth
        case .conciseCleanup: self = .conciseCleanup
        case .fullRewrite: self = .fullRewrite
        case .custom(let id):
            guard let mode = customModes.first(where: { $0.id == id }) else { return nil }
            self = .custom(mode)
        }
    }
}

extension SpeakerAppSettings {
    /// The list entry the saved `refinement` names.
    public var refinementSelection: RefinementModeSelection {
        refinement.selection
    }

    /// Selects `preference`. A Custom Mode outside the list is reconciled as
    /// a decoded one is.
    public mutating func selectRefinement(_ preference: RefinementPreference) {
        refinement = preference
        reconcileRefinementSelection()
    }

    /// Adds `mode` at the end of the list, or replaces the mode with the same
    /// identifier in place. A selected mode stays selected with its new name
    /// and prompt. Returns the trimmed mode that was stored.
    @discardableResult
    public mutating func saveCustomRefinementMode(
        _ mode: CustomRefinementMode
    ) throws -> CustomRefinementMode {
        let validated = try mode.validated()
        if let index = customRefinementModes.firstIndex(where: { $0.id == validated.id }) {
            customRefinementModes[index] = validated
            if refinement.selection == .custom(validated.id) {
                refinement = .custom(validated)
            }
        } else {
            guard customRefinementModes.count < CustomRefinementMode.maximumCount else {
                throw TextRefinementModeValidationError.tooManyCustomModes
            }
            customRefinementModes.append(validated)
        }
        return validated
    }

    /// Removes one Custom Mode. Deleting the selected mode selects Default
    /// Smoothing.
    public mutating func deleteCustomRefinementMode(id: UUID) {
        customRefinementModes.removeAll { $0.id == id }
        if refinement.selection == .custom(id) {
            refinement = .defaultSmooth
        }
    }

    /// Moves one Custom Mode to `index` in the list, clamped to its bounds.
    public mutating func moveCustomRefinementMode(id: UUID, to index: Int) {
        guard let current = customRefinementModes.firstIndex(where: { $0.id == id }) else {
            return
        }
        let mode = customRefinementModes.remove(at: current)
        let destination = min(max(index, 0), customRefinementModes.count)
        customRefinementModes.insert(mode, at: destination)
    }

    /// Keeps `refinement` pointing at a mode in the list. A selected Custom
    /// Mode missing from the list is matched by content, added when there is
    /// room, and otherwise replaced by Default Smoothing.
    mutating func reconcileRefinementSelection() {
        var seen = Set<UUID>()
        customRefinementModes = Array(
            customRefinementModes.filter { seen.insert($0.id).inserted }
                .prefix(CustomRefinementMode.maximumCount))
        guard case .custom(let selected) = refinement else { return }
        if let match = customRefinementModes.first(where: { $0.id == selected.id })
            ?? customRefinementModes.first(where: { $0.hasSameContent(as: selected) })
        {
            refinement = .custom(match)
        } else if customRefinementModes.count < CustomRefinementMode.maximumCount {
            customRefinementModes.append(selected)
        } else {
            refinement = .defaultSmooth
        }
    }

    /// The Custom Mode written under the legacy `savedCustomRefinement` key,
    /// so a build that predates the list still finds one: the selected Custom
    /// Mode, else the first.
    var legacySavedCustomRefinement: RefinementPreference? {
        if case .custom = refinement { return refinement }
        return customRefinementModes.first.map(RefinementPreference.custom)
    }

    /// The list a settings file without `customRefinementModes` implies: its
    /// single saved Custom Mode, if any.
    static func legacyCustomRefinementModes(
        saved: RefinementPreference?
    ) -> [CustomRefinementMode] {
        guard case .custom(let mode) = saved else { return [] }
        return [
            CustomRefinementMode(
                id: CustomRefinementMode.legacySavedID, name: mode.name, prompt: mode.prompt)
        ]
    }
}
