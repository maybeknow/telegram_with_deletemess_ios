# Ghost Mode для iOS-форка — проектирование и точки интеграции

Документ описывает, как повторить Ghost Mode из AyuGram в Telegram-iOS: что блокировать,
где именно в коде это делать, как отправлять сообщения «с задержкой», чтобы пользователь
успел стать офлайн, и какие тут риски.

> **Правка 1 (2026-11-22):** пути проверены по дереву форка. Маркеры: **[ОБНОВЛЕНО]**, **[ДОБАВЛЕНО]**.
>
> **Правка 6 (2026-11-22):** `configLocked` против реентрантного `queue.sync`, тесты на `onChange`
> (main + отсутствие лишних вызовов), проверка владельца `stop()`. Маркеры
> **[ОБНОВЛЕНО 6]**, **[ДОБАВЛЕНО 6]**.
>
> **Правка 5 (2026-11-22):** `onChange` как реальный API (гарантия main), убран сломанный хелпер
> toggle, зафиксировано требование к потоку `configPromise.set`, `stop()` задокументирован,
> тесты с `defer`, добавлен запуск тестов. Маркеры **[ОБНОВЛЕНО 5]**, **[ДОБАВЛЕНО 5]**.
>
> **Правка 4 (2026-11-22):** убрана двойная запись настроек, псевдокод помечен явно, `isActive`
> под локом, добавлены владельцы `start()/stop()`, `LoggerGhostModeLogger`. Маркеры
> **[ОБНОВЛЕНО 4]**, **[ДОБАВЛЕНО 4]**.
>
> **Правка 3 (2026-11-22):** инъекция settings и logger, isActive, отложенный старт offline,
> пересборка entries, уточнён тип GhostModeEntry. Маркеры **[ОБНОВЛЕНО 3]**, **[ДОБАВЛЕНО 3]**.
>
> **Правка 2 (2026-11-22):** уточнены сигнатуры по реальному коду, разделены зоны
> ответственности, добавлены инъекция настроек и тесты. Маркеры: **[ОБНОВЛЕНО 2]**, **[ДОБАВЛЕНО 2]**.
>
> Про Swiftgram: в скачанном оверлее (`Swiftgram-master`, 100 Swift-файлов) реализации ghost
> **нет** — только кейсы `readStories` в перечислениях синхронизации. Готового образца для
> копирования там нет.

---

## 1. Архитектурная схема (текстом)

```
UI (Настройки → Ghost Mode)
        │  пишет флаги (по accountId)
        ▼
GhostModeSettings ──────────────────────────────┐
  per-account: "ayugram.ghost.<accountId>"      │ инжектируется в
  (UserDefaults через KeyValueDataStorage)      │ Gate / OfflineKeeper
        │                                       ▼
        │                          GhostModeGate(accountId:settings:)
        │                            • isBlocked(.readHistory)
        │                            • isBlocked(.updateStatus)
        │                            • isBlocked(.setTyping)
        │                            • isBlocked(.readStories)
        │                                       │
        │                                       ▼
        │                    RPC-точки в TelegramCore (4 файла)
        ▼
GhostModeOutbox ──► enqueueMessages(... scheduleTime: now + delay)
  delay: 12 s текст / max(6, ceil(МБ×4.5)) медиа, с clamp
  cancelScheduled(messageIds:) — отмена «передумал»
```

---

## 2. Структура файлов **[ОБНОВЛЕНО 2]**

```
СОЗДАТЬ (TelegramCore):
submodules/TelegramCore/Sources/GhostMode/GhostModeSettings.swift
submodules/TelegramCore/Sources/GhostMode/GhostModeGate.swift
submodules/TelegramCore/Sources/GhostMode/GhostModeOutbox.swift
submodules/TelegramCore/Sources/GhostMode/GhostModeOfflineKeeper.swift

СОЗДАТЬ (UI, модуль SettingsUI — там же, где AyuGramSettingsController):
submodules/SettingsUI/Sources/GhostModeUI.swift

ИЗМЕНИТЬ (все существуют):
submodules/TelegramCore/Sources/State/ManagedAccountPresence.swift
submodules/TelegramCore/Sources/State/SynchronizePeerReadState.swift
submodules/TelegramCore/Sources/State/ManagedLocalInputActivities.swift        // setTyping
submodules/TelegramCore/Sources/State/TypingDraftStop.swift                    // setTyping (stop)
submodules/TelegramCore/Sources/State/ManagedSynchronizeViewStoriesOperations.swift // readStories
submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift
submodules/SettingsUI/Sources/AyuGramSettingsController.swift                  // секция Ghost Mode
```

---

## 3. Ключевые классы

### 3.1 GhostModeSettings — per-account флаги **[ОБНОВЛЕНО 5]** **[ОБНОВЛЕНО 6]**

```swift
public struct GhostModeConfig: Codable, Equatable {
    public var blocksReadHistory: Bool
    public var blocksUpdateStatus: Bool
    public var blocksTyping: Bool
    public var blocksReadStories: Bool
    public var delayedSend: Bool

    public static let `default` = GhostModeConfig(
        blocksReadHistory: true, blocksUpdateStatus: true,
        blocksTyping: true, blocksReadStories: true, delayedSend: false
    )
}

public protocol KeyValueDataStorage {
    func data(forKey: String) -> Data?
    func setData(_ data: Data?, forKey: String)
}

public final class GhostModeSettings {
    public static let shared = GhostModeSettings()

    private let queue = DispatchQueue(label: "ayugram.ghost.settings")
    private var cache: [Int64: GhostModeConfig] = [:]
    private let storage: KeyValueDataStorage

    /// Вызывается ПОСЛЕ записи и **асинхронно**, на main: `DispatchQueue.main.async { … }`.
    /// Это не «синхронный колбэк внутри update» — важно для тестов: проверять вызов нужно
    /// через XCTestExpectation, а не сразу после `update`.
    public var onChange: ((Int64, GhostModeConfig) -> Void)?

    public init(storage: KeyValueDataStorage = UserDefaultsDataStorage()) {
        self.storage = storage
    }

    private func key(_ accountId: Int64) -> String { "ayugram.ghost.\(accountId)" }

    /// Чтение из кэша/хранилища БЕЗ синхронизации. Вызывать только уже находясь на `queue`
    /// (или когда никакой другой поток не трогает кэш) — иначе получится реентрантный
    /// `queue.sync` на последовательной очереди, то есть дедлок.
    private func configLocked(accountId: Int64) -> GhostModeConfig {
        if let cached = self.cache[accountId] { return cached }
        guard let data = self.storage.data(forKey: self.key(accountId)),
              let value = try? JSONDecoder().decode(GhostModeConfig.self, from: data) else {
            return .default
        }
        self.cache[accountId] = value
        return value
    }

    /// Публичное чтение — единственная точка входа снаружи, берёт очередь один раз.
    public func config(accountId: Int64) -> GhostModeConfig {
        return self.queue.sync {
            self.configLocked(accountId: accountId)
        }
    }

    public func update(accountId: Int64, _ transform: (inout GhostModeConfig) -> Void) {
        let updated: GhostModeConfig? = self.queue.sync {
            // configLocked, а НЕ config: config делает queue.sync и на этой же очереди дал бы дедлок.
            var value = self.configLocked(accountId: accountId)
            transform(&value)
            guard value != self.cache[accountId] else { return nil }
            self.cache[accountId] = value
            if let data = try? JSONEncoder().encode(value) {
                self.storage.setData(data, forKey: self.key(accountId))
            }
            return value
        }
        guard let updated else { return }
        let accountId = accountId
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(accountId, updated)
        }
    }
}
```

Что здесь важно:

- `config(accountId:)` снаружи работает как раньше — внутри один `queue.sync`;
- `update` тоже берёт `queue.sync` ровно один раз и внутри пользуется `configLocked:`,
  поэтому реентрантного `sync` на последовательной очереди нет (это был бы дедлок);
- `onChange` всегда асинхронный и на main.

### 3.2 GhostModeGate — политика блокировок **[ОБНОВЛЕНО 2]**

Параметр `settings` добавлен, чтобы тесты инжектировали своё хранилище и не зависели от
глобального состояния.

```swift
public enum GhostModeRPC {
    case readHistory, readStories, updateStatus, setTyping
}

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
        case .readHistory:  return config.blocksReadHistory
        case .readStories:  return config.blocksReadStories
        case .updateStatus: return config.blocksUpdateStatus
        case .setTyping:    return config.blocksTyping
        }
    }
}
```

### 3.3 GhostModeOutbox **[ОБНОВЛЕНО 2]**

Сигнатуры сверены по коду:

- `OutgoingScheduleInfoMessageAttribute.init(scheduleTime: Int32, repeatPeriod: Int32?)` —
  `submodules/TelegramCore/Sources/SyncCore/SyncCore_OutgoingScheduleInfoMessageAttribute.swift:10`
  ✅ совпадает с документом;
- `deleteMessagesInteractively(messageIds: [MessageId], type: InteractiveMessagesDeletionType, deleteAllInGroup: Bool = false) -> Signal<Void, NoError>` —
  `submodules/TelegramCore/Sources/TelegramEngine/Messages/TelegramEngineMessages.swift:263`
  ✅ принимает **[MessageId]**, а не `[EngineMessage.Id]` (в проекте `EngineMessage.Id` — это
  псевдоним `MessageId`, но в сигнатуре указан базовый тип; ниже использую `[MessageId]`).

```swift
public enum GhostModeOutbox {
    public static func delay(forMediaSize size: Int64?) -> Int32 {
        guard let size, size > 0 else { return 12 }
        let megabytes = Double(size) / (1024.0 * 1024.0)
        let seconds = max(6.0, ceil(megabytes * 4.5))
        return Int32(min(seconds, Double(Int32.max)))   // защита от трапа при переполнении
    }

    public static func scheduleAttribute(delay: Int32, now: Date = Date()) -> OutgoingScheduleInfoMessageAttribute {
        return OutgoingScheduleInfoMessageAttribute(
            scheduleTime: Int32(now.timeIntervalSince1970) + delay,
            repeatPeriod: nil
        )
    }

    /// Отмена «передумал»: сообщение ещё не отправлено, лежит запланированным.
    /// Удаление идёт локально через движок, отдельного RPC не нужно.
    public static func cancelScheduled(engine: TelegramEngine.Messages, messageIds: [MessageId]) {
        let _ = engine.deleteMessagesInteractively(messageIds: messageIds, type: .forLocalPeer)
            .startStandalone()
    }
}
```

**`applyDelay(attributes:delay:now:)` [ДОБАВЛЕНО 7.1].** Появился в реализации шага 3 и
используется в тесте 6.6. Снимает прежний `OutgoingScheduleInfoMessageAttribute` и добавляет
новый, поэтому повторное применение не копит атрибуты расписания (иначе у сообщения оказалось
бы сразу несколько сроков отправки):

```swift
public static func applyDelay(attributes: [MessageAttribute], delay: Int32, now: Date = Date()) -> [MessageAttribute] {
    var attributes = attributes
    attributes.removeAll(where: { $0 is OutgoingScheduleInfoMessageAttribute })
    attributes.append(self.scheduleAttribute(delay: delay, now: now))
    return attributes
}
```


### 3.4 GhostModeOfflineKeeper [ОБНОВЛЕНО 3] [ОБНОВЛЕНО 4]

Задача: перекрывать «онлайн», который выставляется любым другим запросом. Работает **по
событиям** пользователя, таймер — только страховка.

```swift
import Foundation
import SwiftSignalKit

/// Сетевой шов: в тестах подменяется фейком, чтобы не поднимать настоящий Network.
public protocol GhostModeNetwork {
    func sendOffline(_ completion: @escaping (Bool) -> Void)
}

/// Логгер-шов: в приложении — Logger, в тестах — массив строк.
public protocol GhostModeLogger {
    func log(_ message: String)
}

/// Временная реализация для отладки. Перед мержем заменяется на LoggerGhostModeLogger (раздел 9).
public struct PrintGhostModeLogger: GhostModeLogger {
    public init() {}
    public func log(_ message: String) {
        print(message)
    }
}

/// Боевая реализация: пишет в штатный лог приложения.
public struct LoggerGhostModeLogger: GhostModeLogger {
    public init() {}
    public func log(_ message: String) {
        Logger.shared.log("GhostMode", message)
    }
}

public final class GhostModeOfflineKeeper {
    private let queue = Queue()
    private let accountId: Int64
    private let network: GhostModeNetwork
    private let settings: GhostModeSettings
    private let logger: GhostModeLogger
    private var timer: SwiftSignalKit.Timer?

    /// Флаг жизни. Все обращения — только под `queue.sync` (см. isActive / setActive),
    /// иначе completion сетевого запроса, пришедший с другой очереди, читал бы его вне
    /// критической секции: гонка данных и невоспроизводимое поведение в тестах.
    private var isActiveValue = false

    /// Fallback-интервал: 60 с. Почему так:
    ///  - события (notifyActivity) уже покрывают активные действия, таймер — страховка на
    ///    редкие фоновые RPC (getDifference, загрузка медиа);
    ///  - 20 с давали заметное «мигание» статуса и лишний трафик;
    ///  - 60 с — компромисс: статус остаётся офлайн, запросов в минуту всего один.
    private static let fallbackInterval: Double = 60.0

    public init(accountId: Int64, network: GhostModeNetwork, settings: GhostModeSettings = .shared, logger: GhostModeLogger = LoggerGhostModeLogger()) {
        self.accountId = accountId
        self.network = network
        self.settings = settings
        self.logger = logger
    }

    private var isActive: Bool {
        return self.queue.sync { self.isActiveValue }
    }

    private func setActive(_ value: Bool) {
        self.queue.sync { self.isActiveValue = value }
    }

    public func start() {
        self.stop()
        self.setActive(true)
        let timer = SwiftSignalKit.Timer(timeout: Self.fallbackInterval, repeat: true, completion: { [weak self] in
            self?.sendOffline(reason: "fallback-timer")
        }, queue: self.queue)
        timer.start()
        self.timer = timer
        // Сразу после старта: приложение только что поднялось, а любой запрос при старте
        // (getDifference, синхронизация) уже мог выставить «в сети».
        self.sendOffline(reason: "start")
    }

    /// start()/stop() вызываются только с main (владелец — AccountContext), поэтому
    /// timer/invalidate не требуют дополнительной синхронизации: свойство живёт на main.
    /// Флаг isActive при этом защищён queue.sync, потому что его читает completion
    /// сетевого запроса с другой очереди.
    public func stop() {
        self.setActive(false)
        self.timer?.invalidate()
        self.timer = nil
    }

    /// Привязка к действиям пользователя: открыл чат, отправил сообщение, ушёл в фон, начал печатать.
    public func notifyActivity(_ reason: String) {
        self.sendOffline(reason: reason)
    }

    private func sendOffline(reason: String) {
        guard self.isActive else {
            return
        }
        guard GhostModeGate(accountId: self.accountId, settings: self.settings).isBlocked(.updateStatus) else {
            return
        }
        self.network.sendOffline { [weak self] success in
            guard let self, self.isActive else {
                return
            }
            if !success {
                // Не ретраим инлайн: повтор придёт со следующим событием или по fallback-таймеру.
                self.logger.log("[GhostMode] offline request failed (reason: \(reason))")
            }
        }
    }
}
```

**Проверка при реализации [ДОБАВЛЕНО 6].** Убедиться, что `AccountContext` не вызывает
`stop()` с фоновой очереди (типичный случай — из `deinit` или из обработчика сетевого
события). Если вызывает — комментарий «start/stop только с main» станет неверным, и тогда
`timer`/`invalidate` нужно завести под `queue.sync` так же, как `isActive`.

**Кто вызывает `start()` / `stop()` [ДОБАВЛЕНО 4].** Keeper живёт на уровне `AccountContext`:
`start()` — при инициализации контекста (после авторизации) и при возврате приложения в
активный режим; `stop()` — при уходе в фон/деактивации и при закрытии контекста (logout,
смена аккаунта). Альтернатива для фона: не гасить keeper, а полагаться на `isActive` — но
тогда таймер продолжит слать `offline` в фоне, что расходует батарею; поэтому `stop()`.

---

### 3.5 Первая реализация отмены [ДОБАВЛЕНО 8]

Отмена «передумал» в первой версии сделана **тостом `UndoOverlayController`** после отправки,
а не плашкой в composer: тост показывает «Уйдёт через N с» с кнопкой «Отменить», которая
вызывает `GhostModeOutbox.cancelScheduled(engine:messageIds:)`.

Отличия от документа: счётчик секунд не тикает, плашка не связана с полем ввода и живёт
один раз после отправки. Функционально это то же самое — запланированное сообщение можно
отменить. Полноценная composer-плашка со счётчиком — следующий шаг, если понадобится.

Размер медиа для задержки берётся из подтверждённой цепочки
`EnqueueMessage.message(mediaReference:)` → `AnyMediaReference.media as? TelegramMediaFile` →
`.resource.size` (`SyncCore_TelegramMediaFile.swift:703`, `MediaResource.swift:14`);
если размер неизвестен (pending, стриминг) — 12 с.

### 3.6 Подключение keeper в приложении [ДОБАВЛЕНО 9]

- `SharedAccountContext.swift:786` (реальный аккаунт, `updateAccounts`): сразу после создания
  `AccountContextImpl` вызываются `GhostModeOfflineKeeper.shared.configure(accountId:network:)`
  и `start()`. `start()` вызывается **всегда**: `sendOffline` сам проверяет
  `isBlocked(.updateStatus)` и молча выходит, а холостой таймер раз в 60 с почти бесплатен.
  Второй выход `makeTempAccountContext` (`:2028`, `temp: true`) намеренно **не** подключён.
- `AppDelegate.handleDidEnterBackground()` — `notifyActivity("app-background")`.
- `ChatController` после `enqueueMessages` (когда пришли `messageIds`) — `notifyActivity("message-sent")`.
- `ChatController.viewDidAppear` — `notifyActivity("chat-opened")` с флагом по `chatLocation`
  (`ChatLocation: Equatable`, AccountContext.swift:519), иначе возврат из фона или смена таба
  спамили бы keeper.
- **`stop()` при logout не подключён:** в `SharedAccountContext.swift` функции logout нет.
  При смене аккаунта `configure` перезаписывает `accountId`; до перезаписи keeper шлёт offline
  старому аккаунту — это то же, что он делал раньше, вреда нет, после перезаписи работает с новым.

## 4. Точки интеграции **[ОБНОВЛЕНО 2]**

| Файл | Есть? | Что делаем |
|---|---|---|
| `TelegramCore/Sources/State/SynchronizePeerReadState.swift` | ✅ | оба `readHistory` через `GhostModeGate(accountId:settings:)` |
| `TelegramCore/Sources/State/ManagedAccountPresence.swift` | ✅ | см. 4.3 (разделение ответственности) |
| `TelegramCore/Sources/State/StandbyManager.swift` | ❌ нет | заменено на `ManagedLocalInputActivities.swift` + `TypingDraftStop.swift` |
| `TelegramCore/Sources/ApiUtils/TelegramUser.swift` | ✅ | локальный Premium (бит 28), не ghost |
| `TelegramCore/Sources/PendingMessages/EnqueueMessage.swift` | ✅ | атрибут отложенной отправки |
| `SettingsUI/Sources/AyuGramSettingsController.swift` | ✅ | секция Ghost Mode |
| `TelegramUI/Sources/GhostModeUI.swift` | ❌ создать | экран: `SettingsUI/Sources/GhostModeUI.swift` |
| `TelegramCore/Sources/State/ManagedSynchronizeViewStoriesOperations.swift` | ✅ | `stories.readStories` |

### 4.1 setTyping

`ManagedLocalInputActivities.swift:184` (основной) и `TypingDraftStop.swift:98` (остановка):

```swift
if GhostModeGate(accountId: self.account.id.toInt64()).isBlocked(.setTyping) {
    return .complete()
}
```

### 4.2 stories.readStories

`ManagedSynchronizeViewStoriesOperations.swift:125`:

```swift
if GhostModeGate(accountId: self.account.id.toInt64()).isBlocked(.readStories) {
    return .complete()
}
return network.request(Api.functions.stories.readStories(peer: inputPeer, maxId: maxId))
```

Локальную часть (`AccountIntermediateState.UpdateReadStories`, `applyUpdateReadStories`) не
трогаем — иначе поедет локальная лента; см. риск в разделе 7.

### 4.3 ManagedAccountPresence vs GhostModeOfflineKeeper **[ДОБАВЛЕНО 2]**

Раньше эти два места делали одно и то же, и было непонятно, кто за что отвечает. Разделение:

| Компонент | Ответственность | Когда срабатывает |
|---|---|---|
| `GhostModeGate` | **решение**: можно ли отправлять RPC | спрашивается всеми точками перехвата |
| `ManagedAccountPresence` | **штатный** жизненный цикл присутствия: онлайн при активности, офлайн при уходе в фон | при смене сигнала `shouldKeepOnlinePresence` |
| `GhostModeOfflineKeeper` | **принудительный офлайн**: перекрывает онлайн, выставленный другими запросами | по `notifyActivity()` и по fallback-таймеру 60 с |

Правило простое: `ManagedAccountPresence` **не знает** про ghost, кроме **одной проверки** —
в `updatePresence(_ isOnline:)` перед отправкой `updateStatus(offline: .boolFalse)`:

```swift
// ManagedAccountPresence.swift, внутри updatePresence(_:)
if isOnline, GhostModeGate(accountId: self.accountId).isBlocked(.updateStatus) {
    // ghost включён — «я онлайн» не отправляем вообще; перекрывающий offline сделает keeper
    return
}
```

То есть presence **не отправляет online**, но и не берёт на себя роль keeper'а: у него нет
своего таймера переотправки offline. Важное уточнение про таймеры [ОБНОВЛЕНО 7]:

- `onlineTimer` внутри `AccountPresenceManagerImpl` — **собственный** таймер presence: он раз в
  30 секунд «переармливает» online. Когда online запрещён, его надо снимать (`invalidate`), иначе
  presence через 30 с сам себя переиграет и всё-таки отправит online;
- таймер keeper'а (fallback 60 с) — отдельный и принадлежит только `GhostModeOfflineKeeper`.

Поэтому `invalidate(onlineTimer)` в `ManagedAccountPresence` — это снятие собственного таймера
presence, а не нарушение разделения: каждый владеет только своим таймером.

---

## 5. Go Offline Automatically

Механика — в 3.4: `notifyActivity("chat-opened")`, `notifyActivity("message-sent")`,
`notifyActivity("app-background")` из UI; fallback-таймер 60 с. Ошибки логируются.

**Риски при параллельной работе с официальным клиентом:**

- официальный клиент на другом устройстве всё равно шлёт `updateStatus(online)` и
  `readHistory` — аккаунт будет «в сети» **несмотря на** ghost здесь;
- переотправка `offline` даёт «мигание» статуса: собеседник видит «был(а) только что»;
- два клиента создают гонку: сервер применит последний статус, предсказуемости нет;
- блокировка `readHistory` означает, что непрочитанное копится на сервере.

---

## 6. Unit-тесты **[ОБНОВЛЕНО 2]**

Все тесты — без `GhostModeSettings.shared`: каждый создаёт свой экземпляр с `MemoryStorage`,
поэтому тесты не протекают друг в друга (нет общего кэша и нет записи в реальный `UserDefaults`).

```swift
final class MemoryStorage: KeyValueDataStorage {
    private var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { self.values[key] }
    func setData(_ data: Data?, forKey key: String) {
        if let data { self.values[key] = data } else { self.values.removeValue(forKey: key) }
    }
}
```

### 6.1 GhostModeSettings

```swift
func testDefaultsWhenNothingStored() {
    let settings = GhostModeSettings(storage: MemoryStorage())
    XCTAssertEqual(settings.config(accountId: 1), .default)
}

func testAccountsAreIsolated() {
    let settings = GhostModeSettings(storage: MemoryStorage())
    settings.update(accountId: 1) { $0.blocksTyping = false }
    settings.update(accountId: 2) { $0.blocksReadHistory = false }
    XCTAssertFalse(settings.config(accountId: 1).blocksTyping)
    XCTAssertTrue(settings.config(accountId: 2).blocksTyping)
    XCTAssertTrue(settings.config(accountId: 1).blocksReadHistory)
}

func testPersistsAcrossInstances() {
    let storage = MemoryStorage()
    GhostModeSettings(storage: storage).update(accountId: 7) { $0.delayedSend = true }
    XCTAssertTrue(GhostModeSettings(storage: storage).config(accountId: 7).delayedSend)
}
```

### 6.2 GhostModeGate — с инжектированным settings **[ОБНОВЛЕНО 2]**

```swift
final class GhostModeGateTests: XCTestCase {
    private var settings: GhostModeSettings!
    private let accountId: Int64 = 42

    override func setUp() {
        super.setUp()
        self.settings = GhostModeSettings(storage: MemoryStorage())
    }

    override func tearDown() {
        self.settings = nil
        super.tearDown()
    }

    private func gate() -> GhostModeGate {
        GhostModeGate(accountId: self.accountId, settings: self.settings)
    }

    func testAllBlockedByDefault() {
        XCTAssertTrue(gate().isBlocked(.readHistory))
        XCTAssertTrue(gate().isBlocked(.readStories))
        XCTAssertTrue(gate().isBlocked(.updateStatus))
        XCTAssertTrue(gate().isBlocked(.setTyping))
    }

    func testEachFlagIndependently() {
        self.settings.update(accountId: self.accountId) { $0.blocksTyping = false }
        XCTAssertFalse(gate().isBlocked(.setTyping))
        XCTAssertTrue(gate().isBlocked(.readHistory))

        self.settings.update(accountId: self.accountId) { value in
            value.blocksTyping = true
            value.blocksReadStories = false
        }
        XCTAssertTrue(gate().isBlocked(.setTyping))
        XCTAssertFalse(gate().isBlocked(.readStories))
    }

    func testOtherAccountNotAffected() {
        self.settings.update(accountId: 99) { $0.blocksUpdateStatus = false }
        XCTAssertTrue(GhostModeGate(accountId: self.accountId, settings: self.settings).isBlocked(.updateStatus))
        XCTAssertFalse(GhostModeGate(accountId: 99, settings: self.settings).isBlocked(.updateStatus))
    }

    func testTwoInstancesDoNotShareState() {
        let other = GhostModeSettings(storage: MemoryStorage())
        other.update(accountId: self.accountId) { $0.blocksTyping = false }
        XCTAssertTrue(gate().isBlocked(.setTyping), "другой экземпляр настроек не влияет на этот")
    }
}
```

### 6.3 GhostModeOutbox.delay() **[ОБНОВЛЕНО 2]**

```swift
func testTextDelay() {
    XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: nil), 12)
    XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: 0), 12)
}

func testNegativeSizeFallsBackToTextDelay() {
    XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: -1), 12)
    XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: Int64.min), 12)
}

func testSmallMediaMinimumSixSeconds() {
    XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: 1 * 1024 * 1024), 6)
}

func testMediaScalesWithSize() {
    XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: 10 * 1024 * 1024), 45)
    XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: 100 * 1024 * 1024), 450)
}

func testHugeMediaClampsToInt32Max() {
    // Проверяем конкретное значение clamp'а, а не «больше нуля»:
    // без ограничения Int32(Double) трапает, с ограничением — ровно Int32.max.
    XCTAssertEqual(GhostModeOutbox.delay(forMediaSize: Int64.max), Int32.max)
}

func testScheduleAttributeUsesNowPlusDelay() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let attribute = GhostModeOutbox.scheduleAttribute(delay: 12, now: now)
    XCTAssertEqual(attribute.scheduleTime, 1_700_000_012)
    XCTAssertNil(attribute.repeatPeriod)
}
```

### 6.4 GhostModeOfflineKeeper — с фейковыми Network и Logger [ОБНОВЛЕНО 3]

```swift
final class FakeGhostModeNetwork: GhostModeNetwork {
    private(set) var offlineRequests = 0
    var succeeds = true
    var onSend: (() -> Void)?

    func sendOffline(_ completion: @escaping (Bool) -> Void) {
        self.offlineRequests += 1
        self.onSend?()
        completion(self.succeeds)
    }
}

final class RecordingGhostModeLogger: GhostModeLogger {
    private(set) var messages: [String] = []
    func log(_ message: String) { self.messages.append(message) }
}

final class GhostModeOfflineKeeperTests: XCTestCase {
    private func makeSettings(accountId: Int64 = 1, _ transform: (inout GhostModeConfig) -> Void = { _ in }) -> GhostModeSettings {
        let settings = GhostModeSettings(storage: MemoryStorage())
        settings.update(accountId: accountId, transform)
        return settings
    }

    func testDoesNotSendWhenUpdateStatusAllowed() {
        let settings = self.makeSettings { $0.blocksUpdateStatus = false }
        let network = FakeGhostModeNetwork()
        let keeper = GhostModeOfflineKeeper(accountId: 1, network: network, settings: settings)

        keeper.notifyActivity("chat-opened")

        XCTAssertEqual(network.offlineRequests, 0, "ghost выключен — offline не отправляем")
    }

    func testSendsOnEveryActivity() {
        let settings = self.makeSettings()
        let network = FakeGhostModeNetwork()
        let keeper = GhostModeOfflineKeeper(accountId: 1, network: network, settings: settings)

        keeper.notifyActivity("chat-opened")
        keeper.notifyActivity("message-sent")
        keeper.notifyActivity("app-background")

        XCTAssertEqual(network.offlineRequests, 3)
    }

    func testStartSendsImmediately() {
        let settings = self.makeSettings()
        let network = FakeGhostModeNetwork()
        let keeper = GhostModeOfflineKeeper(accountId: 1, network: network, settings: settings)

        defer { keeper.stop() }   // таймер не утечёт даже при провале ассерта
        keeper.start()
        XCTAssertEqual(network.offlineRequests, 1, "start() сразу перекрывает онлайн, выставленный при запуске")
    }

    func testFailureIsRetriedOnNextActivity() {
        let settings = self.makeSettings()
        let network = FakeGhostModeNetwork()
        network.succeeds = false
        let logger = RecordingGhostModeLogger()
        let keeper = GhostModeOfflineKeeper(accountId: 1, network: network, settings: settings, logger: logger)

        keeper.notifyActivity("message-sent")
        XCTAssertEqual(network.offlineRequests, 1)
        XCTAssertEqual(logger.messages.count, 1, "ошибка залогирована, инлайн-ретрая нет")

        network.succeeds = true
        keeper.notifyActivity("chat-opened")
        XCTAssertEqual(network.offlineRequests, 2, "следующее событие ретраит запрос")
        XCTAssertEqual(logger.messages.count, 1, "успех не логируется")
    }

    /// Keeper реагирует только на updateStatus: readHistory/readStories его не касаются.
    func testIgnoresNonUpdateStatusFlags() {
        let settings = self.makeSettings { value in
            value.blocksUpdateStatus = false
            value.blocksReadHistory = true
            value.blocksReadStories = true
        }
        let network = FakeGhostModeNetwork()
        let keeper = GhostModeOfflineKeeper(accountId: 1, network: network, settings: settings)

        defer { keeper.stop() }
        keeper.notifyActivity("chat-opened")
        keeper.start()
        XCTAssertEqual(network.offlineRequests, 0, "блокировка истории не включает перекрывающий offline")
    }

    /// Валиден, пока FakeGhostModeNetwork вызывает onSend синхронно и ДО completion:
    /// тогда stop() успевает снять isActive, и разбор результата видит уже false.
    /// Если фейк станет асинхронным, тест нужно переписать через ожидание (XCTestExpectation).
    func testStopIgnoresInFlightResult() {
        let settings = self.makeSettings()
        let network = FakeGhostModeNetwork()
        let logger = RecordingGhostModeLogger()
        let keeper = GhostModeOfflineKeeper(accountId: 1, network: network, settings: settings, logger: logger)

        network.succeeds = false
        network.onSend = { keeper.stop() }   // stop приходит, пока запрос «в полёте»
        keeper.notifyActivity("message-sent")

        XCTAssertEqual(network.offlineRequests, 1)
        XCTAssertTrue(logger.messages.isEmpty, "после stop() результат in-flight запроса игнорируется")
    }
}
```


### 6.5 GhostModeSettings.onChange **[ДОБАВЛЕНО 6]**

```swift
func testOnChangeFiresOnMainAfterUpdate() {
    let settings = GhostModeSettings(storage: MemoryStorage())
    let expectation = self.expectation(description: "onChange")

    var receivedAccountId: Int64?
    var receivedConfig: GhostModeConfig?
    var wasMainThread = false

    settings.onChange = { accountId, config in
        receivedAccountId = accountId
        receivedConfig = config
        wasMainThread = Thread.isMainThread   // onChange обещан на main
        expectation.fulfill()
    }

    settings.update(accountId: 5) { $0.blocksTyping = false }

    // onChange асинхронный: ждём, а не читаем сразу после update.
    self.wait(for: [expectation], timeout: 1.0)

    XCTAssertEqual(receivedAccountId, 5)
    XCTAssertEqual(receivedConfig?.blocksTyping, false)
    XCTAssertTrue(wasMainThread, "onChange должен приходить на main")
}

func testUpdateDoesNotFireOnChangeWhenValueUnchanged() {
    let settings = GhostModeSettings(storage: MemoryStorage())
    var calls = 0
    settings.onChange = { _, _ in calls += 1 }

    settings.update(accountId: 5) { $0.blocksTyping = false }
    let first = self.expectation(description: "first")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { first.fulfill() }
    self.wait(for: [first], timeout: 1.0)
    XCTAssertEqual(calls, 1)

    // То же значение: кэш не меняется, update возвращает nil, onChange не должен сработать.
    settings.update(accountId: 5) { $0.blocksTyping = false }
    let second = self.expectation(description: "second")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { second.fulfill() }
    self.wait(for: [second], timeout: 1.0)
    XCTAssertEqual(calls, 1, "повторная запись того же значения не дергает подписчика")
}
```

### 6.6 Совместимость с Premium [ДОБАВЛЕНО 7]

```swift
func testGhostModeDoesNotAffectPremiumFlag() {
    // Свой UserDefaults, чтобы не трогать реальные настройки приложения.
    // Имя suite нужно сохранить: removePersistentDomain принимает имя, а не description.
    let suiteName = "ayugram.ghost.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(true, forKey: "ayugram.fakePremium")
    defaults.set(NSNumber(value: 12345), forKey: "ayugram.selfPeerId")

    let settings = GhostModeSettings(storage: InMemoryGhostStorage())
    settings.update(accountId: 1) { $0.blocksTyping = false }
    settings.update(accountId: 1) { $0.blocksReadHistory = false }

    // Ghost пишет только в свой префикс и не касается premium-ключей.
    XCTAssertEqual(defaults.bool(forKey: "ayugram.fakePremium"), true)
    XCTAssertEqual(defaults.object(forKey: "ayugram.selfPeerId") as? NSNumber, NSNumber(value: 12345))
}

func testScheduledMessagesLimitNotExceededLocally() {
    // Клиент лимит не хранит: серверный лимит проверить нельзя. Проверяем то, что в нашей
    // власти — что applyDelay всегда ставит ровно один атрибут расписания, а не копит их.
    let attributes: [MessageAttribute] = []
    let once = GhostModeOutbox.applyDelay(attributes: attributes, delay: 12)
    let twice = GhostModeOutbox.applyDelay(attributes: once, delay: 12)

    let scheduledOnce = once.filter { $0 is OutgoingScheduleInfoMessageAttribute }
    let scheduledTwice = twice.filter { $0 is OutgoingScheduleInfoMessageAttribute }
    XCTAssertEqual(scheduledOnce.count, 1)
    XCTAssertEqual(scheduledTwice.count, 1, "повторное применение заменяет атрибут, а не добавляет второй")
}

func testReadStoriesBlockedWhenGhostEnabled() {
    // Название честное: в клиенте анонимность отдельным флагом не выражена (grep по
    // Story-файлам пуст), поэтому тест проверяет только блокировку stories.readStories:
    // при включённой настройке запрос не уходит вообще, при выключенной — уходит.
    let settings = GhostModeSettings(storage: InMemoryGhostStorage())
    let gate = GhostModeGate(accountId: 1, settings: settings)
    XCTAssertTrue(gate.isBlocked(.readStories))

    settings.update(accountId: 1) { $0.blocksReadStories = false }
    XCTAssertFalse(GhostModeGate(accountId: 1, settings: settings).isBlocked(.readStories))
}
```

## 7. Ограничения и риски **[ОБНОВЛЕНО 2]**

- **Server-side ограничения.** Отложенные сообщения штатны, но сервер знает, когда клиент
  поставил их в очередь — «невидимости» это не даёт.
- **Нарушение ToS.** Скрытие присутствия/чтения/«печатает» может трактоваться как обход
  функциональности; риск санкций остаётся на владельце сборки.
- **Параллельный официальный клиент** обесценивает ghost (см. раздел 5).
- **Неотправленные read-марки.** Блокировка `readHistory` оставляет чаты непрочитанными на сервере.
- **Локально «просмотренные» истории.** Блокируется только `stories.readStories`, а локальное
  состояние просмотра всё равно обновляется (`applyUpdateReadStories`). Итог: **на этом
  устройстве истории выглядят просмотренными, а на сервере и у автора — нет**. При
  переустановке или входе с другого клиента они снова будут непросмотренными, а счётчик
  просмотров у автора не увеличится. Это осознанный компромисс: если блокировать и
  локальную часть, лента будет показывать уже просмотренные истории как новые.
- **Отложенная отправка меняет UX:** сообщение видно как запланированное, при закрытии
  приложения до срока отправка может не произойти; отмена (3.3) обязательна.
- **Premium и лимит отложенных [ОБНОВЛЕНО 7].** При включённом `delayedSend` каждое
  сообщение ставится в отложенные. Лимит отложенных на аккаунт — серверный (Premium его
  поднимает); в клиенте константы нет, поэтому упереться в лимит можно молча: отправка начнёт
  отклоняться сервером. Пока это не обрабатывается отдельно — при большом потоке сообщений с
  включённым ghost возможны отказы.
  **Следующий шаг 7.1 [ДОБАВЛЕНО 7.1]:** при отклонении сервером (лимит отложенных)
  `enqueueMessages` возвращает `Signal<[MessageId?], NoError>`, и ошибка сейчас **не
  обрабатывается отдельно** — тост об отмене показывается, но сообщение просто не уходит.
  Планируется: подписка на ошибку отправки и тост «Не удалось отправить: достигнут лимит
  отложенных сообщений» с предложением выключить задержку. Пока не реализовано.
- **Premium-транскрипция и `setTyping` [ОБНОВЛЕНО 7].** Транскрипция идёт отдельным RPC и
  работает; «печатает… с кастомным статусом» в iOS-клиенте не найдено (в проекте один путь —
  `messages.setTyping`, `ManagedLocalInputActivities.swift:185`), поэтому блокировка `setTyping`
  ломает только индикатор набора, других Premium-проявлений у него нет.
- **Ghost и «отметить прочитанным без отправки» [ОБНОВЛЕНО 7].** Отдельной Premium-функции
  «прочитать, не отправляя» в проекте нет: чтение всегда идёт через
  `SynchronizePeerReadState` / `ManagedSynchronizeViewStoriesOperations`, то есть конфликта
  между двумя механизмами не возникает — есть один, и его ghost блокирует целиком.
- **Тесты.** Изменения в state sync требуют прогона `Tests/StateSync`.

---

## 8. GhostModeUI **[ОБНОВЛЕНО 3]** **[ОБНОВЛЕНО 4]** **[ОБНОВЛЕНО 5]**

Экран показывает конфиг **текущего** аккаунта и перечитывает его при смене аккаунта и после
каждого переключения.

**Про типы-псевдокоды.** В `SettingsUI` нет ни `GhostModeEntry`, ни `GhostModeToggle` — оба
помечены как псевдокод. Реально используются `enum GhostModeEntry: ItemListNodeEntry` (с
`section`, `stableId`, `static func <`, `item(presentationData:arguments:)`, образец —
`AyuGramSettingsControllerEntry`) и **`ItemListSwitchItem`** внутри кейса (или аналог из
`SettingsUI`; сигнатура проверяется при реализации).

```swift
public final class GhostModeUI {
    private let settings: GhostModeSettings
    private let accountId: Int64

    /// accountId захватывается один раз: замыкания не держат self и не уйдут на другой аккаунт.
    public init(context: AccountContext, settings: GhostModeSettings = .shared) {
        self.settings = settings
        self.accountId = context.account.id.toInt64()
    }

    /// Псевдокод: реальный тип — enum, реализующий ItemListNodeEntry.
    /// Каждый пункт пишет ОДИН раз и ровно в своё поле — хелпер с newValue не нужен и убран.
    public func makeEntries() -> [GhostModeEntry] {
        let accountId = self.accountId
        let settings = self.settings
        let config = settings.config(accountId: accountId)

        return [
            .header("GHOST MODE"),
            .toggle(GhostModeToggle(title: "Не отмечать прочитанным", value: config.blocksReadHistory, updated: { newValue in
                settings.update(accountId: accountId) { $0.blocksReadHistory = newValue }
            })),
            .toggle(GhostModeToggle(title: "Не показывать «печатает…»", value: config.blocksTyping, updated: { newValue in
                settings.update(accountId: accountId) { $0.blocksTyping = newValue }
            })),
            .toggle(GhostModeToggle(title: "Не отмечать истории просмотренными", value: config.blocksReadStories, updated: { newValue in
                settings.update(accountId: accountId) { $0.blocksReadStories = newValue }
            })),
            .toggle(GhostModeToggle(title: "Всегда офлайн", value: config.blocksUpdateStatus, updated: { newValue in
                settings.update(accountId: accountId) { $0.blocksUpdateStatus = newValue }
            })),
            .toggle(GhostModeToggle(title: "Отправлять с задержкой", value: config.delayedSend, updated: { newValue in
                settings.update(accountId: accountId) { $0.delayedSend = newValue }
            }))
        ]
    }
}
```

**Как entries пересобираются после toggle.** Основной способ — сигнал; `onChange` из 3.1 —
реальный API, а не псевдокод:

```swift
// В контроллере экрана (main queue гарантирован GhostModeSettings.onChange).
// ignoreRepeated не нужен: GhostModeSettings.update уже не дергает onChange, когда значение
// не изменилось, поэтому дублирующая защита только маскировала бы баги подписки.
let configPromise = ValuePromise<GhostModeConfig>(settings.config(accountId: accountId))

settings.onChange = { [weak self] changedAccountId, config in
    guard let self, changedAccountId == self.accountId else { return }
    // onChange уже приходит на main; если реализация изменится — обернуть в DispatchQueue.main.async.
    configPromise.set(config)
}

let state = configPromise.get()
|> map { config -> (ItemListControllerState, (ItemListNodeState, Any)) in
    (controllerState(config), listState(entries: entries(for: config)))
}
```

`configPromise.set` **обязан** вызываться на main: `ItemListController` перестраивает список
синхронно в подписчике, и обновление из фоновой очереди даёт либо краш, либо «залипший»
переключатель. `GhostModeSettings.onChange` это гарантирует; если реализацию поменяют —
оборачивать в `Queue.main.async`.

**Запасной способ (если экран без сигнала):** пересобрать `makeEntries()` и вызвать у
`ItemListController` перезагрузку — **имя метода проверить при реализации**
(`reload()`/`requestLayout(transition:)` — предположительно).

**Смена аккаунта.** `AccountContext` пересоздаётся при переключении, вместе с ним и экран;
`accountId` берётся заново — подписок не требуется.

---

## 10. Ghost Mode и Premium — совместимость [ДОБАВЛЕНО 7]

Проверено по коду, а не по документации AyuGram. Главный вывод: **прямого конфликта нет** —
ни один Premium-RPC не проходит через наши гейты, потому что гейты блокируют только четыре
запроса (`readHistory`, `readStories`, `setTyping`, `updateStatus`).

| Premium-функция | Как ведёт себя Ghost Mode | Что делать |
|---|---|---|
| **Транскрипция голосовых/видео** | Отдельный RPC: `messages.transcribeAudio` — `Transcription.swift:26` (`_internal_transcribeAudio`). Нашими гейтами **не блокируется**, расшифровка работает. | Ничего. Учесть, что сам запрос делает аккаунт «в сети» на стороне сервера, поэтому keeper пришлёт `offline` следующим событием или по таймеру 60 с. |
| **Анонимный просмотр историй** | Отдельного клиентского флага анонимности в проекте **не найдено** (grep `anonymous` по Story-файлам пуст). Наш блок `stories.readStories` (`ManagedSynchronizeViewStoriesOperations.swift:127`) не сообщает серверу о просмотре **вообще** — это строже, чем анонимный просмотр. | Ничего не менять: блокировка уже покрывает анонимность. Помнить побочный эффект: у автора не растёт счётчик, локально история помечается просмотренной (риск в разделе 7). |
| **Premium-реакции** | Отправка реакции — активное действие, отдельный RPC, гейты его не трогают. | Ничего. Но реакция делает аккаунт онлайн → keeper перекрывает `offline`; собеседник увидит реакцию, но не увидит длительного «в сети». |
| **Отложенные сообщения** | Ghost использует **тот же** механизм (`OutgoingScheduleInfoMessageAttribute`). Лимит отложенных — серверный (Premium его поднимает), клиент его не хранит: в проекте константы лимита нет. | При `delayedSend` каждое сообщение становится отложенным, поэтому при достижении серверного лимита отправка начнёт отклоняться. См. риск в разделе 7. |
| **Папки, темы, стикеры** | Не связаны с ghost-гейтами. Ключи настроек разные: ghost — `ayugram.ghost.<peerId>`, локальный Premium — `ayugram.fakePremium` / `ayugram.selfPeerId`. | Ничего: пересечения ключей нет, `GhostModeSettings` пишет только в свой префикс. |

### 10.1 Локальный Premium и Ghost Mode [ДОБАВЛЕНО 7]

Подмена флага сделана в `TelegramCore/Sources/ApiUtils/TelegramUser.swift`: хелпер
`ayuLocalPremium(flags:id:)` возвращает `true`, если выставлен бит 28 **или** включён
`ayugram.fakePremium` **и** id пользователя совпадает с сохранённым своим. Вызов стоит в двух
местах разбора пользователя (около строк 109 и 256 — бывшие проверки `if (flags & (1 << 28)) != 0`).

Что это значит для Ghost Mode:

- локальный Premium — **чисто клиентская подмена**: сервер по-прежнему считает аккаунт
  обычным, поэтому «валидации Premium через онлайн» не существует, и ghost её сломать не может;
- обратное тоже верно: ghost не влияет на подмену — она читается из `UserDefaults` при разборе
  пользователя, а не из сети;
- серверные Premium-операции (подарки, покупки, реальные лимиты) при локальной подмене
  недоступны и остаются недоступными независимо от ghost.

## 9. Порядок внедрения

1. `GhostModeSettings` + переключатели в экране AyuGram (без перехвата).
2. `GhostModeGate` и блокировка четырёх RPC.
3. `GhostModeOutbox` + отложенная отправка с индикатором и «Отменить».
4. `GhostModeOfflineKeeper` (по событиям, fallback 60 с) + индикатор в шапке чата.
5. Тесты из раздела 6 в `//submodules/TelegramCore:TelegramCoreTests`.
6. **Как запускать тесты [ДОБАВЛЕНО 5]:**
   `python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir ~/telegram-bazel-cache test \
     --configurationPath build-system/appstore-configuration.json \
     --target //submodules/TelegramCore:TelegramCoreTests`
   (в проекте есть только `TelegramCoreTests` как `ios_unit_test`; отдельного таргета
   `GhostModeTests` не создаём — новые тестовые файлы кладём в его источник-группу).
   В CI-прогоне этот таргет по умолчанию не запускается, только по `--target`.
7. **Перед мержем заменить `PrintGhostModeLogger` на `LoggerGhostModeLogger`** (он объявлен в
   разделе 3.4 и пишет через `Logger.shared.log`) — `print` остаётся только для отладки,
   иначе в релизной сборке логи ghost уходят в stdout и не попадают в `ayu-log.txt`.
   [ДОБАВЛЕНО 4]
