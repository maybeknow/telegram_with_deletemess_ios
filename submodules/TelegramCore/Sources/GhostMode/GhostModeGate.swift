import Foundation

/// Какой RPC проверяем перед отправкой.
public enum GhostModeRPC {
    case readHistory
    case readStories
    case updateStatus
    case setTyping
}

/// Политика Ghost Mode: единственное место, где решается, можно ли отправлять RPC.
///
/// Настройки инжектируются, чтобы тесты не зависели от глобального состояния.
public struct GhostModeGate {
    public let accountId: Int64
    private let settings: GhostModeSettings

    public init(accountId: Int64, settings: GhostModeSettings = .shared) {
        self.accountId = accountId
        self.settings = settings
    }

    public func isBlocked(_ rpc: GhostModeRPC) -> Bool {
        let config = self.settings.config(accountId: self.accountId)
        switch rpc {
        case .readHistory:
            return config.blocksReadHistory
        case .readStories:
            return config.blocksReadStories
        case .updateStatus:
            return config.blocksUpdateStatus
        case .setTyping:
            return config.blocksTyping
        }
    }
}
