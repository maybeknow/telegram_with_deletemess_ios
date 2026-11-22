import Foundation
import Postbox

/// Отложенная отправка для Ghost Mode.
///
/// Идея: пока включён `delayedSend`, сообщение не уходит сразу, а ставится в отложенные на
/// несколько секунд — за это время пользователь успевает «уйти в офлайн», а собеседник не
/// видит мгновенной активности. Механизм отложенных сообщений в проекте уже есть, отдельного
/// транспорта не требуется: достаточно атрибута `OutgoingScheduleInfoMessageAttribute`.
public enum GhostModeOutbox {
    /// Задержка для текста.
    public static let textDelay: Int32 = 12

    /// Задержка по размеру медиа: `max(6, ceil(МБ * 4.5))`, с ограничением сверху, чтобы
    /// `Int32(...)` не трапнул на огромном файле.
    public static func delay(forMediaSize size: Int64?) -> Int32 {
        guard let size, size > 0 else {
            return self.textDelay
        }
        let megabytes = Double(size) / (1024.0 * 1024.0)
        let seconds = max(6.0, ceil(megabytes * 4.5))
        return Int32(min(seconds, Double(Int32.max)))
    }

    /// Атрибут отложенной отправки: `scheduleTime = now + delay`.
    public static func scheduleAttribute(delay: Int32, now: Date = Date()) -> OutgoingScheduleInfoMessageAttribute {
        return OutgoingScheduleInfoMessageAttribute(
            scheduleTime: Int32(now.timeIntervalSince1970) + delay,
            repeatPeriod: nil
        )
    }

    /// Добавляет атрибут отложенной отправки к списку атрибутов сообщения.
    public static func applyDelay(attributes: [MessageAttribute], delay: Int32, now: Date = Date()) -> [MessageAttribute] {
        var attributes = attributes
        attributes.removeAll(where: { $0 is OutgoingScheduleInfoMessageAttribute })
        attributes.append(self.scheduleAttribute(delay: delay, now: now))
        return attributes
    }

    /// Отмена «передумал»: сообщение ещё не отправлено и лежит запланированным, поэтому
    /// удаляется локально через движок сообщений, без отдельного RPC.
    public static func cancelScheduled(engine: TelegramEngine.Messages, messageIds: [MessageId]) {
        let _ = engine.deleteMessagesInteractively(messageIds: messageIds, type: .scheduledMessages).startStandalone()
    }
}

extension GhostModeOutbox {
    /// Размер медиа у сообщения, которое готовится к отправке.
    ///
    /// Источник размера подтверждён по коду:
    /// `TelegramMediaFile.resource: TelegramMediaResource` (SyncCore_TelegramMediaFile.swift:703)
    /// и `MediaResource.size: Int64?` (Postbox/Sources/MediaResource.swift:14).
    /// Если медиа нет, размер неизвестен или это не файл (стриминг, pending без метаданных) —
    /// возвращаем `nil`, и вызывающий использует текстовую задержку 12 с.
    public static func mediaSize(for message: EnqueueMessage) -> Int64? {
        guard case let .message(_, _, _, mediaReference, _, _, _, _, _, _) = message, let reference = mediaReference else {
            return nil
        }
        guard let file = reference.media as? TelegramMediaFile else {
            return nil
        }
        return file.resource.size
    }
}
