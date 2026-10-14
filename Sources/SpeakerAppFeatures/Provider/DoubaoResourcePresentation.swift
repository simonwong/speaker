import SpeakerCore

/// How Settings names a Doubao streaming resource and explains a failed
/// connection check for it.
package enum DoubaoResourcePresentation {
    /// The default resource is the one a new Key is usually activated for,
    /// so it carries the recommendation for users who are unsure.
    package static func title(for resource: DoubaoStreamingResource) -> String {
        resource == .default ? "\(resource.displayName)（推荐）" : resource.displayName
    }

    /// What the selected resource costs. Only the recommended resource has a
    /// published per-hour price worth turning into a monthly estimate
    /// (volcengine.com/docs/6561/1359370, checked 2026-10).
    package static func costNote(for resource: DoubaoStreamingResource) -> String {
        switch resource {
        case .model2Duration:
            "按音频时长计费，标价 1 元/小时。每天说 30 分钟，一个月约 15 元。"
        case .model1Duration:
            "按音频时长计费，价格以火山引擎计费说明为准。"
        case .model2Concurrent, .model1Concurrent:
            "按并发路数计费，价格以火山引擎计费说明为准。"
        }
    }

    /// A rejected resource or Key gets its own fix; other failures use the
    /// shared problem title.
    package static func connectionFailure(
        _ failure: DoubaoASRFailure,
        resource: DoubaoStreamingResource
    ) -> String {
        switch failure.kind {
        case .cancelled:
            "连接检查已取消"
        case .resourceNotActivated:
            "这个 Key 没有开通「\(resource.displayName)」。请在豆包控制台开通它，或在「流式资源」里改选已开通的资源。"
        case .invalidCredential:
            "API Key 无效。请复制豆包控制台里的 API Key，不要填 APP ID 或 Access Token。"
        default:
            VoiceInputProblem(doubaoFailure: failure).failure.userTitle
        }
    }
}
