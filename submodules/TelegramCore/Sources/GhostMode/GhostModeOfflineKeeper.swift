import Foundation
import SwiftSignalKit
import Postbox
internal import TelegramApi

/// Сетевой шов: в тестах подменяется фейком, чтобы не поднимать настоящий Network.
public protocol GhostModeNetwork {
    func sendOffline(_ completion: @escaping (Bool) -> Void)
}

/// Логгер-шов: в приложении пишет в штатный лог, в тестах — в массив строк.
public protocol GhostModeLogger {
    func log(_ message: String)
}

public struct TelegramGhostModeLogger: GhostModeLogger {
    public init() {}
    public func log(_ message: String) {
        Logger.shared.log("GhostMode", message)
    }
}

/// Боевой адаптер над Network: единственный RPC, который здесь нужен, — `account.updateStatus`.
public final class TelegramGhostModeNetwork: GhostModeNetwork {
    private let network: Network

    public init(network: Network) {
        self.network = network
    }

    public func sendOffline(_ completion: @escaping (Bool) -> Void) {
        let _ = self.network.request(Api.functions.account.updateStatus(offline: .boolTrue))
            .start(next: { _ in
                completion(true)
            }, error: { _ in
                completion(false)
            })
    }
}

/// Держит аккаунт офлайн: перекрывает «онлайн», который выставляет любой другой запрос.
///
/// Работает по событиям пользователя (`notifyActivity`), а таймер — только страховка для
/// редких фоновых RPC. Владелец — уровень AccountContext: он вызывает `start()`/`stop()`
/// на активации/деактивации. Оба метода обязаны вызываться с главного потока, поэтому
/// `timer`/`invalidate` не синхронизируются; флаг `isActive` защищён очередью, так как его
/// читает completion сетевого запроса с другой очереди.
public final class GhostModeOfflineKeeper {
    public static let shared = GhostModeOfflineKeeper()

    /// `Queue.sync` в этом проекте не возвращает значение, поэтому состояние защищено обычным
    /// локом, а сетевые вызовы и таймер остаются как были.
    private let lock = NSLock()
    private var accountIdValue: Int64?
    private var networkValue: GhostModeNetwork?
    private var isActiveValue = false
    private let settings: GhostModeSettings
    private let logger: GhostModeLogger
    private var timer: SwiftSignalKit.Timer?

    /// Страховочный интервал: 60 с. События покрывают активные действия; таймер нужен только
    /// чтобы перекрыть редкие фоновые RPC. 20 с давали заметное «мигание» статуса и лишний
    /// трафик, 60 с — один запрос в минуту при сохранении офлайна.
    public static let fallbackInterval: Double = 60.0

    public init(settings: GhostModeSettings = .shared, logger: GhostModeLogger = TelegramGhostModeLogger()) {
        self.settings = settings
        self.logger = logger
    }

    /// Привязка к аккаунту. Вызывается, когда AccountContext становится доступен.
    public func configure(accountId: Int64, network: GhostModeNetwork) {
        self.lock.lock()
        self.accountIdValue = accountId
        self.networkValue = network
        self.lock.unlock()
    }

    public var accountId: Int64? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.accountIdValue
    }

    private var isActive: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.isActiveValue
    }

    private func setActive(_ value: Bool) {
        self.lock.lock()
        self.isActiveValue = value
        self.lock.unlock()
    }

    private func currentState() -> (accountId: Int64, network: GhostModeNetwork)? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let accountId = self.accountIdValue, let network = self.networkValue else {
            return nil
        }
        return (accountId, network)
    }

    public func start() {
        self.stop()
        self.setActive(true)
        let timer = SwiftSignalKit.Timer(timeout: Self.fallbackInterval, repeat: true, completion: { [weak self] in
            self?.sendOffline(reason: "fallback-timer")
        }, queue: .mainQueue())
        timer.start()
        self.timer = timer
        // Приложение только что поднялось: любой стартовый запрос уже мог выставить «в сети».
        self.sendOffline(reason: "start")
    }

    public func stop() {
        self.setActive(false)
        self.timer?.invalidate()
        self.timer = nil
    }

    /// Привязка к действиям: открытие чата, отправка сообщения, уход в фон.
    public func notifyActivity(_ reason: String) {
        self.sendOffline(reason: reason)
    }

    private func sendOffline(reason: String) {
        guard self.isActive else {
            return
        }
        guard let (accountId, network) = self.currentState() else {
            return
        }
        guard GhostModeGate(accountId: accountId, settings: self.settings).isBlocked(.updateStatus) else {
            return
        }
        network.sendOffline { [weak self] success in
            guard let self, self.isActive else {
                return
            }
            if !success {
                // Не ретраим инлайн: повтор придёт со следующим событием или по таймеру.
                self.logger.log("[GhostMode] offline request failed (reason: \(reason))")
            }
        }
    }
}
