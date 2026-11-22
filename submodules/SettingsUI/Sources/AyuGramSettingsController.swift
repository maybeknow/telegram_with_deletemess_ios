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
    case ghost
}

private final class AyuGramSettingsControllerArguments {
    let updateKeepDeleted: (Bool) -> Void
    let updateForwardCopy: (Bool) -> Void
    let updateFakePremium: (Bool) -> Void
    let updateGhostMode: (Bool) -> Void
    var presentBannerPicker: (() -> Void)?
    let updateMark: (String) -> Void
    var presentMarkEditor: (() -> Void)?
    let updateGhost: ((inout GhostModeConfig) -> Void) -> Void

    init(
        updateKeepDeleted: @escaping (Bool) -> Void,
        updateForwardCopy: @escaping (Bool) -> Void,
        updateFakePremium: @escaping (Bool) -> Void,
        updateGhostMode: @escaping (Bool) -> Void,
        updateMark: @escaping (String) -> Void,
        updateGhost: @escaping ((inout GhostModeConfig) -> Void) -> Void
    ) {
        self.updateKeepDeleted = updateKeepDeleted
        self.updateForwardCopy = updateForwardCopy
        self.updateFakePremium = updateFakePremium
        self.updateGhostMode = updateGhostMode
        self.updateMark = updateMark
        self.updateGhost = updateGhost
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
    case bannerButton
    case bannerFooter

    case markHeader
    case mark(String)
    case markFooter

    case ghostHeader
    case readHistory(Bool)
    case typing(Bool)
    case readStories(Bool)
    case alwaysOffline(Bool)
    case delayedSend(Bool)
    case ghostFooter

    var section: ItemListSectionId {
        switch self {
        case .messagesHeader, .keepDeleted, .forwardCopy, .messagesFooter:
            return AyuGramSection.messages.rawValue
        case .premiumHeader, .fakePremium, .premiumFooter:
            return AyuGramSection.premium.rawValue
        case .privacyHeader, .ghostMode, .privacyFooter:
            return AyuGramSection.privacy.rawValue
        case .bannerHeader, .banner, .bannerButton, .bannerFooter:
            return AyuGramSection.banner.rawValue
        case .markHeader, .mark, .markFooter:
            return AyuGramSection.mark.rawValue
        case .ghostHeader, .readHistory, .typing, .readStories, .alwaysOffline, .delayedSend, .ghostFooter:
            return AyuGramSection.ghost.rawValue
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
        case .bannerFooter: return 13
        case .bannerButton: return 12
        case .markHeader: return 14
        case .mark: return 15
        case .markFooter: return 16
        case .ghostHeader: return 17
        case .readHistory: return 18
        case .typing: return 19
        case .readStories: return 20
        case .alwaysOffline: return 21
        case .delayedSend: return 22
        case .ghostFooter: return 23
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
        case .bannerButton:
            return ItemListActionItem(presentationData: presentationData, title: AyuGramBanner.hasBanner ? "Заменить баннер" : "Выбрать баннер", kind: .generic, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.presentBannerPicker?()
            })
        case .bannerFooter:
            return ItemListTextItem(presentationData: presentationData, text: .markdown("Своя картинка в шапке профиля: обрезается под пропорции шапки и хранится только на этом устройстве."), sectionId: self.section)
        case .markHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "МЕТКА УДАЛЁННОГО", sectionId: self.section)
        case let .mark(value):
            return ItemListDisclosureItem(presentationData: presentationData, title: "Текст метки", label: value, sectionId: self.section, style: .blocks, action: {
                arguments.presentMarkEditor?()
            })
        case .markFooter:
            return ItemListTextItem(presentationData: presentationData, text: .markdown("Показывается перед временем у сохранённого удалённого сообщения. Пустое поле возвращает корзину."), sectionId: self.section)
        case .ghostHeader:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "GHOST MODE", sectionId: self.section)
        case let .readHistory(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Не отмечать прочитанным", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateGhost { $0.blocksReadHistory = value }
            })
        case let .typing(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Не показывать «печатает…»", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateGhost { $0.blocksTyping = value }
            })
        case let .readStories(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Не отмечать истории просмотренными", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateGhost { $0.blocksReadStories = value }
            })
        case let .alwaysOffline(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Всегда офлайн", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateGhost { $0.blocksUpdateStatus = value }
            })
        case let .delayedSend(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Отправлять с задержкой", value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.updateGhost { $0.delayedSend = value }
            })
        case .ghostFooter:
            return ItemListTextItem(presentationData: presentationData, text: .markdown("Пока включён Ghost Mode, клиент не отправляет серверу прочтение, набор текста, просмотр историй и не выставляет себя в сети. Параллельный официальный клиент этот режим не соблюдает."), sectionId: self.section)
        }
    }
}

private func ayuGramSettingsControllerEntries(presentationData: PresentationData, accountId: Int64) -> [AyuGramSettingsControllerEntry] {
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
    entries.append(.bannerButton)
    entries.append(.bannerFooter)

    entries.append(.markHeader)
    entries.append(.mark((UserDefaults.standard.object(forKey: ayuDeletedMarkKey) as? String) ?? "\u{1F5D1}\u{FE0E}"))
    entries.append(.markFooter)

    let ghost = GhostModeSettings.shared.config(accountId: accountId)
    entries.append(.ghostHeader)
    entries.append(.readHistory(ghost.blocksReadHistory))
    entries.append(.typing(ghost.blocksTyping))
    entries.append(.readStories(ghost.blocksReadStories))
    entries.append(.alwaysOffline(ghost.blocksUpdateStatus))
    entries.append(.delayedSend(ghost.delayedSend))
    entries.append(.ghostFooter)

    return entries
}

/// Экран «Настройки → AyuGram»: те же строки, заголовки и отступы, что у «Архива» и «Оформления»,
/// потому что это те же элементы ItemListUI.
public func ayuGramSettingsController(context: AccountContext) -> ViewController {
    // GhostModeGate используется и в местах без accountPeerId в сигнатуре — запоминаем id,
    // чтобы политика блокировок работала и там.
    let arguments = AyuGramSettingsControllerArguments(
        updateKeepDeleted: { value in
            UserDefaults.standard.set(value, forKey: ayuKeepDeletedKey)
        },
        updateForwardCopy: { value in
            UserDefaults.standard.set(value, forKey: ayuForwardCopyKey)
        },
        updateFakePremium: { value in
            UserDefaults.standard.set(value, forKey: ayuFakePremiumKey)
            // Свой id нужен ядру, чтобы подменить флаг премиума только у этого аккаунта.
            if value {
                UserDefaults.standard.set(context.account.peerId.toInt64(), forKey: "ayugram.selfPeerId")
            }
        },
        updateGhostMode: { value in
            UserDefaults.standard.set(value, forKey: ayuGhostModeKey)
        },
        updateMark: { value in
            UserDefaults.standard.set(value.isEmpty ? "\u{1F5D1}\u{FE0E}" : value, forKey: ayuDeletedMarkKey)
        },
        updateGhost: { transform in
            GhostModeSettings.shared.update(accountId: context.account.peerId.toInt64()) { config in
                transform(&config)
            }
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
            entries: ayuGramSettingsControllerEntries(presentationData: presentationData, accountId: context.account.peerId.toInt64()),
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

    arguments.presentMarkEditor = { [weak controller] in
        guard let controller else {
            return
        }
        let current = (UserDefaults.standard.object(forKey: ayuDeletedMarkKey) as? String) ?? "\u{1F5D1}\u{FE0E}"
        let alert = UIAlertController(title: "Текст метки", message: "Показывается перед временем у удалённого сообщения", preferredStyle: .alert)
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

    // Метка удалённого: обычное текстовое поле в алерте, значение хранится в UserDefaults
    // и переживает перезапуск приложения.
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
