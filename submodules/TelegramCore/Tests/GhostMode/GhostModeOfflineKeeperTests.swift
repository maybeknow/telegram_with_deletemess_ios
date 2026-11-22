import XCTest

private final class FakeGhostModeNetwork: GhostModeNetwork {
    private(set) var offlineRequests = 0
    var succeeds = true
    var onSend: (() -> Void)?

    func sendOffline(_ completion: @escaping (Bool) -> Void) {
        self.offlineRequests += 1
        self.onSend?()
        completion(self.succeeds)
    }
}

private final class RecordingGhostModeLogger: GhostModeLogger {
    private(set) var messages: [String] = []
    func log(_ message: String) { self.messages.append(message) }
}

final class GhostModeOfflineKeeperTests: XCTestCase {
    private func makeSettings(_ transform: (inout GhostModeConfig) -> Void = { _ in }) -> GhostModeSettings {
        let settings = GhostModeSettings(storage: InMemoryGhostStorage())
        settings.update(accountId: 1, transform)
        return settings
    }

    func testDoesNotSendWhenUpdateStatusAllowed() {
        let settings = self.makeSettings { $0.blocksUpdateStatus = false }
        let network = FakeGhostModeNetwork()
        let keeper = GhostModeOfflineKeeper(settings: settings)
        keeper.configure(accountId: 1, network: network)

        keeper.notifyActivity("chat-opened")

        XCTAssertEqual(network.offlineRequests, 0, "ghost выключен — offline не отправляем")
    }

    func testSendsOnEveryActivity() {
        let settings = self.makeSettings()
        let network = FakeGhostModeNetwork()
        let keeper = GhostModeOfflineKeeper(settings: settings)
        keeper.configure(accountId: 1, network: network)
        keeper.start()
        defer { keeper.stop() }

        let afterStart = network.offlineRequests
        keeper.notifyActivity("chat-opened")
        keeper.notifyActivity("message-sent")
        keeper.notifyActivity("app-background")

        XCTAssertEqual(network.offlineRequests, afterStart + 3)
    }

    func testStartSendsImmediately() {
        let settings = self.makeSettings()
        let network = FakeGhostModeNetwork()
        let keeper = GhostModeOfflineKeeper(settings: settings)
        keeper.configure(accountId: 1, network: network)

        defer { keeper.stop() }
        keeper.start()
        XCTAssertEqual(network.offlineRequests, 1, "start() сразу перекрывает онлайн после запуска")
    }

    func testFailureIsRetriedOnNextActivity() {
        let settings = self.makeSettings()
        let network = FakeGhostModeNetwork()
        network.succeeds = false
        let logger = RecordingGhostModeLogger()
        let keeper = GhostModeOfflineKeeper(settings: settings, logger: logger)
        keeper.configure(accountId: 1, network: network)
        keeper.start()
        defer { keeper.stop() }

        let base = network.offlineRequests
        keeper.notifyActivity("message-sent")
        XCTAssertEqual(network.offlineRequests, base + 1)
        XCTAssertEqual(logger.messages.count, 1, "ошибка залогирована, инлайн-ретрая нет")

        network.succeeds = true
        keeper.notifyActivity("chat-opened")
        XCTAssertEqual(network.offlineRequests, base + 2, "следующее событие ретраит запрос")
    }

    func testIgnoresNonUpdateStatusFlags() {
        let settings = self.makeSettings { value in
            value.blocksUpdateStatus = false
            value.blocksReadHistory = true
            value.blocksReadStories = true
        }
        let network = FakeGhostModeNetwork()
        let keeper = GhostModeOfflineKeeper(settings: settings)
        keeper.configure(accountId: 1, network: network)

        defer { keeper.stop() }
        keeper.notifyActivity("chat-opened")
        keeper.start()
        XCTAssertEqual(network.offlineRequests, 0, "блокировка истории не включает перекрывающий offline")
    }

    /// Валиден, пока фейк вызывает onSend синхронно и ДО completion.
    func testStopIgnoresInFlightResult() {
        let settings = self.makeSettings()
        let network = FakeGhostModeNetwork()
        let logger = RecordingGhostModeLogger()
        let keeper = GhostModeOfflineKeeper(settings: settings, logger: logger)
        keeper.configure(accountId: 1, network: network)
        keeper.start()
        defer { keeper.stop() }

        network.succeeds = false
        keeper.stop()
        keeper.notifyActivity("message-sent")

        XCTAssertTrue(logger.messages.isEmpty, "после stop() запросы не отправляются и не логируются")
    }
}

private final class InMemoryGhostStorage: KeyValueDataStorage {
    private var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { self.values[key] }
    func setData(_ data: Data?, forKey key: String) {
        if let data { self.values[key] = data } else { self.values.removeValue(forKey: key) }
    }
}
