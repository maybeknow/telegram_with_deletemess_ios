import Foundation
import Postbox

/// AyuGram-style local premium ("fake premium"): this build treats its own account as a Telegram Premium subscriber
/// without the server knowing, the way AyuGram's Android build does with its `localPremium` preference
/// (`AyuConfig.localPremium`, read here as the switch below).
///
/// Everything the app decides on the client side then behaves as for a subscriber: the premium sticker and emoji
/// picker, premium reactions and message effects, premium limits (pinned chats, folders, chat links, sticker sets),
/// animated profile photos, transcription, and the premium-only trappings of the profile and of the composer. What the
/// server decides stays decided by the server — a request that needs a real subscription is still refused, and the
/// account is still not premium to anyone else. This is a local illusion, exactly like AyuGram's.
public enum AyuGramPremium {
    /// Ключ настройки; значение пишет экран AyuGram в настройках, читают и ядро, и оболочка.
    public static let settingsKey = "ayugram.fakePremium"

    /// `false` restores the stock behaviour everywhere this build consults it.
    public static var isEnabled: Bool {
        if let value = UserDefaults.standard.object(forKey: self.settingsKey) as? Bool {
            return value
        }
        return true
    }
}

/// Whether this account is premium as far as the client is concerned: a real subscription, or the local fake above.
///
/// Every TelegramCore gate on whether *this* account is premium reads the account peer, so they all go through here;
/// a gate that reads `transaction.getPeer(account.peerId)?.isPremium` directly would drift from the rest of the build
/// the moment the switch is flipped.
func accountIsPremium(transaction: Transaction, accountPeerId: PeerId) -> Bool {
    if AyuGramPremium.isEnabled {
        return true
    }
    return transaction.getPeer(accountPeerId)?.isPremium ?? false
}
