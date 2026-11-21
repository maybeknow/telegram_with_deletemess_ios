import Foundation

/// Настройки AyuGram. Хранятся в `UserDefaults`, поэтому их читает и оболочка приложения
/// (`TelegramUI`), и ядро (`TelegramCore`), которое не может импортировать UI.
///
/// Ключи и значения по умолчанию продублированы в местах чтения: там они берутся напрямую из
/// `UserDefaults.standard`, чтобы ядро не зависело от этого файла.
public enum AyuGramSettings {
    public static let keepDeletedMessagesKey = "ayugram.keepDeletedMessages"
    public static let fakePremiumKey = "ayugram.fakePremium"
    public static let deletedMarkKey = "ayugram.deletedMark"
    public static let forwardDeletedAsCopyKey = "ayugram.forwardDeletedAsCopy"

    public static let defaultDeletedMark = "🗑"

    public static var keepDeletedMessages: Bool {
        get {
            if let value = UserDefaults.standard.object(forKey: self.keepDeletedMessagesKey) as? Bool {
                return value
            }
            return true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: self.keepDeletedMessagesKey)
        }
    }

    public static var fakePremium: Bool {
        get {
            if let value = UserDefaults.standard.object(forKey: self.fakePremiumKey) as? Bool {
                return value
            }
            return true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: self.fakePremiumKey)
        }
    }

    public static var deletedMark: String {
        get {
            if let value = UserDefaults.standard.object(forKey: self.deletedMarkKey) as? String {
                return value
            }
            return self.defaultDeletedMark
        }
        set {
            UserDefaults.standard.set(newValue, forKey: self.deletedMarkKey)
        }
    }

    /// Пересылка сохранённого удалённого сообщения копией: сервер такой id уже не знает, поэтому
    /// обычный forward возвращает ошибку.
    public static var forwardDeletedAsCopy: Bool {
        get {
            if let value = UserDefaults.standard.object(forKey: self.forwardDeletedAsCopyKey) as? Bool {
                return value
            }
            return true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: self.forwardDeletedAsCopyKey)
        }
    }
}
