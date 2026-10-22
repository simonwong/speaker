import Foundation

package enum DoubaoConnectionStatus: Equatable, Sendable {
    case loading
    case unconfigured
    case configured
    case checking
    case success(String?)
    case failure(String)

    /// The status line's longer explanation, shown on hover.
    package var summary: String {
        switch self {
        case .loading:
            "正在读取本机配置…"
        case .unconfigured:
            "未配置"
        case .configured:
            "已保存在这台 Mac"
        case .checking:
            "正在检查连接…"
        case .success(let requestID):
            requestID.map { "连接成功 · \($0)" } ?? "连接成功"
        case .failure(let message):
            message
        }
    }
}
