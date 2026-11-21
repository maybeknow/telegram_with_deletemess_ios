import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext

private let ayuKeepDeletedKey = "ayugram.keepDeletedMessages"
private let ayuFakePremiumKey = "ayugram.fakePremium"
private let ayuDeletedMarkKey = "ayugram.deletedMark"
private let ayuForwardCopyKey = "ayugram.forwardDeletedAsCopy"
private let ayuGhostModeKey = "ayugram.ghostMode"

private func ayuBool(_ key: String, defaultValue: Bool) -> Bool {
    if let value = UserDefaults.standard.object(forKey: key) as? Bool {
        return value
    }
    return defaultValue
}

private enum AyuGramSection: Int32 {
    case messages
    case premium
    case privacy
}

private final class AyuGramSettingsControllerArguments {
    let updateKeepDeleted: (Bool) -> Void
    let updateForwardCopy: (Bool) -> Void
    let updateFakePremium: (Bool) -> Void
    let updateGhostMode: (Bool) -> Void

    init(
        updateKeepDeleted: @escaping (Bool) -> Void,
        updateForwardCopy: @escaping (Bool) -> Void,
        updateFakePremium: @escaping (Bool) -> Void,
        updateGhostMode: @escaping (Bool) -> Void
    ) {
        self.updateKeepDeleted = updateKeepDeleted
        self.updateForwardCopy = updateForwardCopy
        self.updateFakePremium = updateFakePremium
        self.updateGhostMode = updateGhostMode
    }
}

private enum AyuGramSettingsControllerEntry: ItemListNodeEntry {
    case messagesHeader
    case keepDeleted(Bool)
    case forwardCopy(Bool)
    case messagesFooter

    case premiumHeader
    case fakePremium(Bool)
    case premiumFooter

    case privacyHeader
    case ghostMode(Bool)
    case privacyFooter

    var section: ItemListSectionId {
        switch self {
        case .messagesHeader, .keepDeleted, .forwardCopy, .messagesFooter:
            return AyuGramSection.messages.rawValue
        case .premiumHeader, .fakePremium, .premiumFooter:
            return AyuGramSection.premium.rawValue
        case .privacyHeader, .ghostMode, .privacyFooter:
            return AyuGramSection.privacy.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .messagesHeader: return 0
        case .keepDeleted: return 1
        case .forwardCopy: return 2
        case .messagesFooter: return 3
        case .premiumHeader: return 4
        case .fakePremium: return 5
        case .premiumFooter: return 6
        case .privacyHeader: return 7
        case .ghostMode: return 8
        case .privacyFooter: return 9
        }
    }

    static func <(lhs: AyuGramSettingsControllerEntry, rhs: AyuGramSettingsControllerEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AyuGramSettingsControllerArguments
        switch self {
        case .messagesHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "СООБЩЕНИЯ", sectionId: self.section)
        case let .keepDeleted(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Сохранять удалённые сообщения", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateKeepDeleted(value)
            })
        case let .forwardCopy(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Пересылать удалённые копией", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateForwardCopy(value)
            })
        case .messagesFooter:
            return ItemListTextItem(presentationData: presentationData, text: .markdown("Удалённое собеседником сообщение остаётся в чате с меткой; пересылка уходит копией, потому что сервер исходное сообщение уже не знает."), sectionId: self.section)
        case .premiumHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "ПРЕМИУМ", sectionId: self.section)
        case let .fakePremium(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Локальный Premium", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateFakePremium(value)
            })
        case .premiumFooter:
            return ItemListTextItem(presentationData: presentationData, text: .markdown("Клиент считает аккаунт премиумом, сервер — нет. После переключения перезапусти приложение."), sectionId: self.section)
        case .privacyHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "ПРИВАТНОСТЬ", sectionId: self.section)
        case let .ghostMode(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Ghost mode", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateGhostMode(value)
            })
        case .privacyFooter:
            return ItemListTextItem(presentationData: presentationData, text: .markdown("Аккаунт всегда офлайн для собеседников: вместо «в сети» серверу отправляется offline."), sectionId: self.section)
        }
    }
}

private func ayuGramSettingsControllerEntries(presentationData: PresentationData) -> [AyuGramSettingsControllerEntry] {
    var entries: [AyuGramSettingsControllerEntry] = []

    entries.append(.messagesHeader)
    entries.append(.keepDeleted(ayuBool(ayuKeepDeletedKey, defaultValue: true)))
    entries.append(.forwardCopy(ayuBool(ayuForwardCopyKey, defaultValue: true)))
    entries.append(.messagesFooter)

    entries.append(.premiumHeader)
    entries.append(.fakePremium(ayuBool(ayuFakePremiumKey, defaultValue: true)))
    entries.append(.premiumFooter)

    entries.append(.privacyHeader)
    entries.append(.ghostMode(ayuBool(ayuGhostModeKey, defaultValue: false)))
    entries.append(.privacyFooter)

    return entries
}

/// Экран «Настройки → AyuGram»: те же строки, заголовки и отступы, что у «Архива» и «Оформления»,
/// потому что это те же элементы ItemListUI.
public func ayuGramSettingsController(context: AccountContext) -> ViewController {
    let arguments = AyuGramSettingsControllerArguments(
        updateKeepDeleted: { value in
            UserDefaults.standard.set(value, forKey: ayuKeepDeletedKey)
        },
        updateForwardCopy: { value in
            UserDefaults.standard.set(value, forKey: ayuForwardCopyKey)
        },
        updateFakePremium: { value in
            UserDefaults.standard.set(value, forKey: ayuFakePremiumKey)
        },
        updateGhostMode: { value in
            UserDefaults.standard.set(value, forKey: ayuGhostModeKey)
        }
    )

    let signal = context.sharedContext.presentationData
    |> deliverOnMainQueue
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var presentationData = presentationData
        presentationData = presentationData.withUpdated(theme: presentationData.theme.withModalBlocksBackground())

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("AyuGram"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: ayuGramSettingsControllerEntries(presentationData: presentationData),
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    return controller
}
