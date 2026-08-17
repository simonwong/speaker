/// Display mode for a provider API Key card (Doubao and DeepSeek are
/// isomorphic). A saved key is never shown next to a persistent input box;
/// the input appears only before the first save or inside an explicit
/// "更换 Key" expansion.
package enum APIKeyCardMode: Equatable, Sendable {
    /// No key saved: the input field is the card's primary content.
    case enterKey
    /// Key saved: status badge plus 检查连接 / 更换 Key / 删除 actions.
    case configured
    /// Key saved and "更换 Key" expanded: configured actions plus inline input.
    case replacingKey
}

package enum APIKeyCardPresentation {
    package static func mode(
        hasStoredKey: Bool,
        isReplacingKey: Bool
    ) -> APIKeyCardMode {
        guard hasStoredKey else { return .enterKey }
        return isReplacingKey ? .replacingKey : .configured
    }
}
