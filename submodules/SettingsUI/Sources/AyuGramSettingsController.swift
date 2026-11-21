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
    case privacy
    case mark
    case banner
}

/// Экран «Настройки → AyuGram». Собран на `ItemListController`, как «Архив» и «Оформление»:
/// те же блоки, отступы и шрифты, потому что это те же элементы списка.
public func ayuGramSettingsController(context: AccountContext) -> ViewController {
    let signal = context.sharedContext.presentationData
    |> deliverOnMainQueue
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var presentationData = presentationData
        presentationData = presentationData.withUpdated(theme: presentationData.theme.withModalBlocksBackground())

        var messages: [ItemListEntry] = []
        messages.append(ItemListSwitchItem(
            presentationData: ItemListPresentationData(presentationData),
            title: "Сохранять удалённые сообщения",
            text: "Сообщение, удалённое собеседником, остаётся в чате с меткой",
            value: ayuBool(ayuKeepDeletedKey, defaultValue: true),
            sectionId: AyuGramSection.messages.rawValue,
            style: .blocks,
            updated: { value in
                UserDefaults.standard.set(value, forKey: ayuKeepDeletedKey)
            }
        ))
        messages.append(ItemListSwitchItem(
            presentationData: ItemListPresentationData(presentationData),
            title: "Пересылать удалённые копией",
            text: "Сервер уже не знает удалённое сообщение, поэтому уходит копия",
            value: ayuBool(ayuForwardCopyKey, defaultValue: true),
            sectionId: AyuGramSection.messages.rawValue,
            style: .blocks,
            updated: { value in
                UserDefaults.standard.set(value, forKey: ayuForwardCopyKey)
            }
        ))

        var privacy: [ItemListEntry] = []
        privacy.append(ItemListSwitchItem(
            presentationData: ItemListPresentationData(presentationData),
            title: "Локальный Premium",
            text: "Клиент считает аккаунт премиумом, сервер — нет",
            value: ayuBool(ayuFakePremiumKey, defaultValue: true),
            sectionId: AyuGramSection.privacy.rawValue,
            style: .blocks,
            updated: { value in
                UserDefaults.standard.set(value, forKey: ayuFakePremiumKey)
            }
        ))
        privacy.append(ItemListSwitchItem(
            presentationData: ItemListPresentationData(presentationData),
            title: "Ghost mode",
            text: "Аккаунт всегда офлайн для собеседников",
            value: ayuBool(ayuGhostModeKey, defaultValue: false),
            sectionId: AyuGramSection.privacy.rawValue,
            style: .blocks,
            updated: { value in
                UserDefaults.standard.set(value, forKey: ayuGhostModeKey)
            }
        ))

        var mark: [ItemListEntry] = []
        mark.append(ItemListTextInputItem(
            presentationData: ItemListPresentationData(presentationData),
            title: "Метка удалённого",
            text: (UserDefaults.standard.object(forKey: ayuDeletedMarkKey) as? String) ?? "\u{1F5D1}\u{FE0E}",
            placeholder: "\u{1F5D1}\u{FE0E}",
            sectionId: AyuGramSection.mark.rawValue,
            style: .blocks,
            updated: { value in
                UserDefaults.standard.set(value.isEmpty ? "\u{1F5D1}\u{FE0E}" : value, forKey: ayuDeletedMarkKey)
            }
        ))

        var banner: [ItemListEntry] = []
        banner.append(ItemListDisclosureItem(
            presentationData: ItemListPresentationData(presentationData),
            title: "Баннер профиля",
            label: AyuGramBanner.hasBanner ? "Выбран" : "Не выбран",
            sectionId: AyuGramSection.banner.rawValue,
            style: .blocks,
            action: {
            }
        ))

        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("AyuGram"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: [
                ItemListSection(id: AyuGramSection.messages.rawValue, header: .text("СООБЩЕНИЯ"), items: messages),
                ItemListSection(id: AyuGramSection.privacy.rawValue, header: .text("ПРИВАТНОСТЬ И ПРЕМИУМ"), items: privacy),
                ItemListSection(id: AyuGramSection.mark.rawValue, header: .text("МЕТКА УДАЛЁННОГО"), items: mark),
                ItemListSection(id: AyuGramSection.banner.rawValue, header: .text("БАННЕР ПРОФИЛЯ"), items: banner)
            ],
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, 0 as Any))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    return controller
}
