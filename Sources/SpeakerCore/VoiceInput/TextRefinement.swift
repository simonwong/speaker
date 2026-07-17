import Foundation

public enum TextRefinementMode: Equatable, Hashable, Sendable {
    public static let maximumCustomNameLength = 80
    public static let maximumCustomPromptLength = 4_000

    case defaultSmooth
    case conciseCleanup
    case fullRewrite
    case custom(name: String, prompt: String)

    public var requiresDeepSeek: Bool {
        self != .defaultSmooth
    }

    public var displayName: String {
        switch self {
        case .defaultSmooth:
            "默认顺滑"
        case .conciseCleanup:
            "精简清理"
        case .fullRewrite:
            "完整重写"
        case let .custom(name, _):
            name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public var diagnosticKind: String {
        switch self {
        case .defaultSmooth: "defaultSmooth"
        case .conciseCleanup: "conciseCleanup"
        case .fullRewrite: "fullRewrite"
        case .custom: "custom"
        }
    }

    public func validated() throws -> TextRefinementMode {
        switch self {
        case .defaultSmooth, .conciseCleanup, .fullRewrite:
            return self
        case let .custom(name, prompt):
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty else {
                throw TextRefinementModeValidationError.emptyCustomName
            }
            guard cleanName.count <= Self.maximumCustomNameLength else {
                throw TextRefinementModeValidationError.customNameTooLong
            }
            guard !cleanPrompt.isEmpty else {
                throw TextRefinementModeValidationError.emptyCustomPrompt
            }
            guard cleanPrompt.count <= Self.maximumCustomPromptLength else {
                throw TextRefinementModeValidationError.customPromptTooLong
            }
            return .custom(name: cleanName, prompt: cleanPrompt)
        }
    }

    var deepSeekRule: String? {
        switch self {
        case .defaultSmooth:
            nil
        case .conciseCleanup:
            "删除不影响原意的口头禅、重复、自我修正和明显冗余；修正标点与语序；尽量保留原句结构、语气和信息量。不要概括，不要扩写。"
        case .fullRewrite:
            "在不增加、删除或改变事实与意图的前提下，重新组织为清晰、连贯、可以直接发送的文字；可以调整句序和段落，但不要补充标题、背景、论据或结论，除非原文已经包含。"
        case let .custom(_, prompt):
            prompt
        }
    }
}

public enum TextRefinementModeValidationError: String, Error, Equatable, Sendable {
    case emptyCustomName
    case customNameTooLong
    case emptyCustomPrompt
    case customPromptTooLong
}

extension TextRefinementModeValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyCustomName:
            "规则名称不能为空。"
        case .customNameTooLong:
            "规则名称不能超过 \(TextRefinementMode.maximumCustomNameLength) 个字符。"
        case .emptyCustomPrompt:
            "整理规则不能为空。"
        case .customPromptTooLong:
            "整理规则不能超过 \(TextRefinementMode.maximumCustomPromptLength) 个字符。"
        }
    }
}

public struct DeepSeekRefinementResult: Equatable, Sendable {
    public let text: String
    public let providerRequestID: String?

    public init(text: String, providerRequestID: String? = nil) {
        self.text = text
        self.providerRequestID = providerRequestID
    }
}

public protocol DeepSeekTextRefining: Sendable {
    func refine(_ text: String, using mode: TextRefinementMode) async throws -> DeepSeekRefinementResult
}

public enum DeepSeekRefinementStatus: String, Equatable, Sendable {
    case notRequested
    case succeeded
    case fellBack
}

public struct TextRefinementOutcome: Equatable, Sendable {
    public let doubaoText: String
    public let deepSeekText: String?
    public let finalText: String
    public let mode: TextRefinementMode
    public let status: DeepSeekRefinementStatus
    public let failure: DeepSeekRefinementFailure?
    public let providerRequestID: String?

    public init(
        doubaoText: String,
        deepSeekText: String?,
        finalText: String,
        mode: TextRefinementMode,
        status: DeepSeekRefinementStatus,
        failure: DeepSeekRefinementFailure?,
        providerRequestID: String? = nil
    ) {
        self.doubaoText = doubaoText
        self.deepSeekText = deepSeekText
        self.finalText = finalText
        self.mode = mode
        self.status = status
        self.failure = failure
        self.providerRequestID = providerRequestID
    }
}

/// Owns the product fallback guarantee: optional refinement can improve a
/// successful transcript, but can never turn it into a failed voice input.
public actor OptionalTextRefinementPipeline {
    private let refiner: any DeepSeekTextRefining

    public init(refiner: any DeepSeekTextRefining) {
        self.refiner = refiner
    }

    public func refine(
        doubaoText: String,
        mode: TextRefinementMode
    ) async throws -> TextRefinementOutcome {
        guard mode.requiresDeepSeek else {
            return TextRefinementOutcome(
                doubaoText: doubaoText,
                deepSeekText: nil,
                finalText: doubaoText,
                mode: mode,
                status: .notRequested,
                failure: nil,
                providerRequestID: nil
            )
        }

        do {
            try Task.checkCancellation()
            let validatedMode = try mode.validated()
            let result = try await refiner.refine(doubaoText, using: validatedMode)
            try Task.checkCancellation()
            return TextRefinementOutcome(
                doubaoText: doubaoText,
                deepSeekText: result.text,
                finalText: result.text,
                mode: validatedMode,
                status: .succeeded,
                failure: nil,
                providerRequestID: result.providerRequestID
            )
        } catch let failure as DeepSeekRefinementFailure {
            if failure.kind == .cancelled {
                throw CancellationError()
            }
            return fallback(doubaoText: doubaoText, mode: mode, failure: failure)
        } catch let validation as TextRefinementModeValidationError {
            return fallback(
                doubaoText: doubaoText,
                mode: mode,
                failure: DeepSeekRefinementFailure(
                    kind: .invalidMode,
                    message: validation.rawValue
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return fallback(
                doubaoText: doubaoText,
                mode: mode,
                failure: DeepSeekRefinementFailure(kind: .unexpected)
            )
        }
    }

    private func fallback(
        doubaoText: String,
        mode: TextRefinementMode,
        failure: DeepSeekRefinementFailure
    ) -> TextRefinementOutcome {
        TextRefinementOutcome(
            doubaoText: doubaoText,
            deepSeekText: nil,
            finalText: doubaoText,
            mode: mode,
            status: .fellBack,
            failure: failure,
            providerRequestID: failure.providerRequestID
        )
    }
}
