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

extension GhostModeGate {
    /// Для точек, где id аккаунта не проброшен параметром (см. отчёт по шагу 2: в
    /// `TypingDraftStop` и `pushStoriesAreSeen` его нет в сигнатуре). Берём последний известный
    /// id: его проставляет экран настроек и любая запись конфига. Для одного аккаунта на
    /// устройстве это эквивалентно явной передаче.
    public static var fallbackAccountId: Int64 {
        get {
            return Int64(UserDefaults.standard.object(forKey: "ayugram.currentAccountId") as? NSNumber ?? 0)
        }
        set {
            UserDefaults.standard.set(NSNumber(value: newValue), forKey: "ayugram.currentAccountId")
        }
    }

    /// Проверка без явного id: используется там, где аккаунт неизвестен в сигнатуре.
    public static func isBlocked(_ rpc: GhostModeRPC, settings: GhostModeSettings = .shared) -> Bool {
        return GhostModeGate(accountId: GhostModeGate.fallbackAccountId, settings: settings).isBlocked(rpc)
    }
}
