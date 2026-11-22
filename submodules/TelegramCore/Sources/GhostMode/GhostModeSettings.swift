import Foundation

/// Конфигурация Ghost Mode для одного аккаунта.
///
/// Флаги означают «запретить отправку соответствующего RPC»: пока флаг включён, клиент не
/// сообщает серверу о прочтении, о наборе текста, о просмотре историй, а также не выставляет
/// себя «в сети». Значения хранятся per-account: у каждого аккаунта в приложении свой набор.
public struct GhostModeConfig: Codable, Equatable {
    public var blocksReadHistory: Bool
    public var blocksUpdateStatus: Bool
    public var blocksTyping: Bool
    public var blocksReadStories: Bool
    public var delayedSend: Bool

    public init(
        blocksReadHistory: Bool,
        blocksUpdateStatus: Bool,
        blocksTyping: Bool,
        blocksReadStories: Bool,
        delayedSend: Bool
    ) {
        self.blocksReadHistory = blocksReadHistory
        self.blocksUpdateStatus = blocksUpdateStatus
        self.blocksTyping = blocksTyping
        self.blocksReadStories = blocksReadStories
        self.delayedSend = delayedSend
    }

    public static let `default` = GhostModeConfig(
        blocksReadHistory: true,
        blocksUpdateStatus: true,
        blocksTyping: true,
        blocksReadStories: true,
        delayedSend: false
    )
}

/// Хранилище значений по ключу. Вынесено в протокол, чтобы тесты работали в памяти и не
/// трогали настоящий `UserDefaults`.
public protocol KeyValueDataStorage {
    func data(forKey: String) -> Data?
    func setData(_ data: Data?, forKey: String)
}

public struct UserDefaultsDataStorage: KeyValueDataStorage {
    private let defaults: UserDefaults

    public init(suiteName: String? = nil) {
        if let suiteName, let defaults = UserDefaults(suiteName: suiteName) {
            self.defaults = defaults
        } else {
            self.defaults = UserDefaults.standard
        }
    }

    public func data(forKey key: String) -> Data? {
        return self.defaults.data(forKey: key)
    }

    public func setData(_ data: Data?, forKey key: String) {
        self.defaults.set(data, forKey: key)
    }
}

/// Настройки Ghost Mode: флаги по каждому аккаунту плюс уведомление об изменениях.
///
/// Все чтения и записи идут через последовательную очередь. Внутри записи используется
/// `configLocked`, потому что `queue.sync` на этой же очереди из `config(accountId:)` дал бы
/// реентрантный вызов и дедлок.
public final class GhostModeSettings {
    public static let shared = GhostModeSettings()

    private let queue = DispatchQueue(label: "ayugram.ghost.settings")
    private var cache: [Int64: GhostModeConfig] = [:]
    private let storage: KeyValueDataStorage

    /// Вызывается после изменения значения, **асинхронно на главном потоке**: обработчики
    /// интерфейса подписываются на него и не должны думать о переключении очередей.
    public var onChange: ((Int64, GhostModeConfig) -> Void)?

    public init(storage: KeyValueDataStorage = UserDefaultsDataStorage()) {
        self.storage = storage
    }

    private func storageKey(_ accountId: Int64) -> String {
        return "ayugram.ghost.\(accountId)"
    }

    /// Чтение без синхронизации: вызывать только уже находясь на `queue`.
    private func configLocked(accountId: Int64) -> GhostModeConfig {
        if let cached = self.cache[accountId] {
            return cached
        }
        guard let data = self.storage.data(forKey: self.storageKey(accountId)),
              let value = try? JSONDecoder().decode(GhostModeConfig.self, from: data) else {
            return .default
        }
        self.cache[accountId] = value
        return value
    }

    /// Текущие настройки аккаунта. Без записи — чистое чтение.
    public func config(accountId: Int64) -> GhostModeConfig {
        return self.queue.sync {
            return self.configLocked(accountId: accountId)
        }
    }

    /// Изменяет настройки аккаунта. Если значение не изменилось, подписчик не вызывается.
    public func update(accountId: Int64, _ transform: (inout GhostModeConfig) -> Void) {
        let updated: GhostModeConfig? = self.queue.sync {
            var value = self.configLocked(accountId: accountId)
            transform(&value)
            guard value != self.cache[accountId] else {
                return nil
            }
            self.cache[accountId] = value
            if let data = try? JSONEncoder().encode(value) {
                self.storage.setData(data, forKey: self.storageKey(accountId))
            }
            return value
        }

        guard let updated else {
            return
        }
        let changedAccountId = accountId
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(changedAccountId, updated)
        }
    }
}
