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

private var ayuBannerPresenters: [AyuBannerPickerPresenter] = []

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
    case banner
    case mark
}

private final class AyuGramSettingsControllerArguments {
    let updateKeepDeleted: (Bool) -> Void
    let updateForwardCopy: (Bool) -> Void
    let updateFakePremium: (Bool) -> Void
    let updateGhostMode: (Bool) -> Void
    var presentBannerPicker: (() -> Void)?
    var presentMarkEditor: (() -> Void)?

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

    case bannerHeader
    case banner
    case bannerFooter

    case markHeader
    case mark
    case markFooter

    var section: ItemListSectionId {
        switch self {
        case .messagesHeader, .keepDeleted, .forwardCopy, .messagesFooter:
            return AyuGramSection.messages.rawValue
        case .premiumHeader, .fakePremium, .premiumFooter:
            return AyuGramSection.premium.rawValue
        case .privacyHeader, .ghostMode, .privacyFooter:
            return AyuGramSection.privacy.rawValue
        case .bannerHeader, .banner, .bannerFooter:
            return AyuGramSection.banner.rawValue
        case .markHeader, .mark, .markFooter:
            return AyuGramSection.mark.rawValue
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
        case .bannerHeader: return 10
        case .banner: return 11
        case .bannerFooter: return 12
        case .markHeader: return 13
        case .mark: return 14
        case .markFooter: return 15
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
        case .bannerHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "БАННЕР ПРОФИЛЯ", sectionId: self.section)
        case .banner:
            return ItemListDisclosureItem(presentationData: presentationData, title: "Баннер профиля", label: AyuGramBanner.hasBanner ? "Выбран" : "Не выбран", sectionId: self.section, style: .blocks, action: {
                arguments.presentBannerPicker?()
            })
        case .bannerFooter:
            return ItemListTextItem(presentationData: presentationData, text: .markdown("Своя картинка в шапке профиля: обрезается под пропорции шапки и хранится только на этом устройстве."), sectionId: self.section)
        case .markHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "МЕТКА УДАЛЁННОГО", sectionId: self.section)
        case .mark:
            let mark = (UserDefaults.standard.object(forKey: ayuDeletedMarkKey) as? String) ?? "\u{1F5D1}\u{FE0E}"
            return ItemListDisclosureItem(presentationData: presentationData, title: "Текст метки", label: mark, sectionId: self.section, style: .blocks, action: {
                arguments.presentMarkEditor?()
            })
        case .markFooter:
            return ItemListTextItem(presentationData: presentationData, text: .markdown("Показывается перед временем у сохранённого удалённого сообщения. Пустое поле возвращает корзину."), sectionId: self.section)
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

    entries.append(.bannerHeader)
    entries.append(.banner)
    entries.append(.bannerFooter)

    entries.append(.markHeader)
    entries.append(.mark)
    entries.append(.markFooter)

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

    // Выбор картинки баннера: презентер держим в статике, иначе он умрёт вместе с замыканием.
    let bannerPresenter = AyuBannerPickerPresenter(controller: controller)
    ayuBannerPresenters.append(bannerPresenter)
    arguments.presentBannerPicker = { [weak bannerPresenter] in
        bannerPresenter?.present()
    }

    // Метка удалённого: обычное текстовое поле в алерте, значение хранится в UserDefaults
    // и переживает перезапуск приложения.
    arguments.presentMarkEditor = { [weak controller] in
        guard let controller else {
            return
        }
        let current = (UserDefaults.standard.object(forKey: ayuDeletedMarkKey) as? String) ?? "\u{1F5D1}\u{FE0E}"
        let alert = UIAlertController(title: "Метка удалённого", message: "Текст перед временем у сохранённого сообщения", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = current
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Сохранить", style: .default, handler: { _ in
            let value = alert.textFields?.first?.text ?? ""
            UserDefaults.standard.set(value.isEmpty ? "\u{1F5D1}\u{FE0E}" : value, forKey: ayuDeletedMarkKey)
        }))
        alert.addAction(UIAlertAction(title: "Сбросить", style: .destructive, handler: { _ in
            UserDefaults.standard.set("\u{1F5D1}\u{FE0E}", forKey: ayuDeletedMarkKey)
        }))
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel, handler: nil))
        controller.present(alert, animated: true, completion: nil)
    }

    return controller
}


/// Выбор картинки для баннера: держит ссылку на контроллер и сохраняет выбранное фото.
private final class AyuBannerPickerPresenter: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private weak var controller: ViewController?

    init(controller: ViewController) {
        self.controller = controller
    }

    func present() {
        guard let controller else {
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = self
        controller.present(picker, animated: true, completion: nil)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        if let image = info[.originalImage] as? UIImage {
            let _ = AyuGramBanner.save(image: image)
        }
        picker.dismiss(animated: true, completion: nil)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true, completion: nil)
    }
}
