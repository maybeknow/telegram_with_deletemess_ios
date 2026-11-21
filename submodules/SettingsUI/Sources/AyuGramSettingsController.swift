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

/// Экран «Настройки → AyuGram» на штатных элементах ItemListUI, поэтому размеры строк,
/// отступы, шрифты и поведение совпадают с остальными настройками Telegram.
public func ayuGramSettingsController(context: AccountContext) -> ViewController {
    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        var presentationData = presentationData
        presentationData = presentationData.withUpdated(theme: presentationData.theme.withModalBlocksBackground())

        let listPresentationData = ItemListPresentationData(presentationData)

        var entries: [ItemListEntry] = []

        entries.append(ItemListSwitchItem(
            presentationData: listPresentationData,
            title: "Сохранять удалённые сообщения",
            text: "Удалённое собеседником сообщение остаётся в чате с меткой",
            value: ayuBool(ayuKeepDeletedKey, defaultValue: true),
            sectionId: 0,
            style: .blocks,
            updated: { value in
                UserDefaults.standard.set(value, forKey: ayuKeepDeletedKey)
            }
        ))
        entries.append(ItemListSwitchItem(
            presentationData: listPresentationData,
            title: "Пересылать удалённые копией",
            text: "Сервер не знает удалённое сообщение, поэтому уходит копия",
            value: ayuBool(ayuForwardCopyKey, defaultValue: true),
            sectionId: 0,
            style: .blocks,
            updated: { value in
                UserDefaults.standard.set(value, forKey: ayuForwardCopyKey)
            }
        ))

        entries.append(ItemListSwitchItem(
            presentationData: listPresentationData,
            title: "Локальный Premium",
            text: "Клиент считает аккаунт премиумом, сервер — нет",
            value: ayuBool(ayuFakePremiumKey, defaultValue: true),
            sectionId: 1,
            style: .blocks,
            updated: { value in
                UserDefaults.standard.set(value, forKey: ayuFakePremiumKey)
            }
        ))
        entries.append(ItemListSwitchItem(
            presentationData: listPresentationData,
            title: "Ghost mode",
            text: "Аккаунт всегда офлайн для собеседников",
            value: ayuBool(ayuGhostModeKey, defaultValue: false),
            sectionId: 1,
            style: .blocks,
            updated: { value in
                UserDefaults.standard.set(value, forKey: ayuGhostModeKey)
            }
        ))

        entries.append(ItemListDisclosureItem(
            presentationData: listPresentationData,
            title: "Метка удалённого",
            label: (UserDefaults.standard.object(forKey: ayuDeletedMarkKey) as? String) ?? "\u{1F5D1}\u{FE0E}",
            sectionId: 2,
            style: .blocks,
            action: {
                // Сброс к метке по умолчанию: поле ввода в этом наборе элементов отсутствует,
                // поэтому нажатие возвращает стандартную корзину AyuGram.
                UserDefaults.standard.set("\u{1F5D1}\u{FE0E}", forKey: ayuDeletedMarkKey)
            }
        ))
        entries.append(ItemListDisclosureItem(
            presentationData: listPresentationData,
            title: "Баннер профиля",
            label: AyuGramBanner.hasBanner ? "Выбран" : "Не выбран",
            sectionId: 2,
            style: .blocks,
            action: {
            }
        ))

        let controllerState = ItemListControllerState(
            presentationData: listPresentationData,
            title: .text("AyuGram"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
        )
        let listState = ItemListNodeState(
            presentationData: listPresentationData,
            entries: entries,
            style: .blocks,
            animateChanges: true
        )
        return (controllerState, (listState, 0 as Any))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.navigationPresentation = .modal
    return controller
}
