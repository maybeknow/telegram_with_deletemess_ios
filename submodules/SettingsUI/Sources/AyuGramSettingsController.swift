import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramCore
import TelegramPresentationData
import AccountContext

/// Экран настроек AyuGram. Открывается из «Настройки → AyuGram» (см. `openSettings(section: .ayuGram)`).
///
/// Значения читаются и пишутся прямо в `UserDefaults` по тем же ключам, что использует ядро
/// (`AyuGramPremium.isEnabled`, `StateReplay+Messages.swift`), поэтому экран не зависит от TelegramUI.
public func ayuGramSettingsController(context: AccountContext) -> ViewController {
    return AyuGramSettingsController(context: context)
}

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

private final class AyuGramSettingsController: ViewController {
    private let context: AccountContext

    private var scrollView: UIScrollView?
    private var keepDeletedSwitch: UISwitch?
    private var fakePremiumSwitch: UISwitch?
    private var forwardCopySwitch: UISwitch?
    private var markField: UITextField?
    private var ghostSwitch: UISwitch?

    init(context: AccountContext) {
        self.context = context

        super.init(navigationBarPresentationData: nil)

        self.title = "AyuGram"
        self.statusBar.statusBarStyle = .Black
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.context.sharedContext.currentPresentationData.with { $0 }.theme.list.blocksBackgroundColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        self.view.addSubview(scrollView)
        self.scrollView = scrollView

        var y: CGFloat = 16.0
        let inset: CGFloat = 16.0

        y = self.addSection(title: "УДАЛЁННЫЕ СООБЩЕНИЯ", scrollView: scrollView, y: y, inset: inset, presentationData: presentationData)

        self.keepDeletedSwitch = self.addRow(
            title: "Сохранять удалённые сообщения",
            detail: "Сообщение, удалённое собеседником, остаётся в чате",
            scrollView: scrollView,
            y: &y,
            inset: inset,
            presentationData: presentationData,
            isOn: ayuBool(ayuKeepDeletedKey, defaultValue: true),
            action: #selector(self.keepDeletedChanged(_:))
        )

        self.forwardCopySwitch = self.addRow(
            title: "Пересылать удалённые копией",
            detail: "Вместо forward отправляется копия текста",
            scrollView: scrollView,
            y: &y,
            inset: inset,
            presentationData: presentationData,
            isOn: ayuBool(ayuForwardCopyKey, defaultValue: true),
            action: #selector(self.forwardCopyChanged(_:))
        )

        y = self.addSection(title: "ПРИВАТНОСТЬ", scrollView: scrollView, y: y, inset: inset, presentationData: presentationData)

        self.ghostSwitch = self.addRow(
            title: "Ghost mode",
            detail: "Аккаунт всегда офлайн для собеседников",
            scrollView: scrollView,
            y: &y,
            inset: inset,
            presentationData: presentationData,
            isOn: ayuBool(ayuGhostModeKey, defaultValue: false),
            action: #selector(self.ghostChanged(_:))
        )

        y = self.addSection(title: "ПРЕМИУМ", scrollView: scrollView, y: y, inset: inset, presentationData: presentationData)
        self.fakePremiumSwitch = self.addRow(
            title: "Локальный Premium",
            detail: "Клиент считает аккаунт премиумом, сервер — нет",
            scrollView: scrollView,
            y: &y,
            inset: inset,
            presentationData: presentationData,
            isOn: ayuBool(ayuFakePremiumKey, defaultValue: true),
            action: #selector(self.fakePremiumChanged(_:))
        )

        y = self.addSection(title: "МЕТКА УДАЛЁННОГО", scrollView: scrollView, y: y, inset: inset, presentationData: presentationData)

        let field = UITextField()
        field.text = (UserDefaults.standard.object(forKey: ayuDeletedMarkKey) as? String) ?? "🗑"
        field.font = UIFont.systemFont(ofSize: 17.0)
        field.textColor = presentationData.theme.list.itemPrimaryTextColor
        field.backgroundColor = presentationData.theme.list.itemBlocksBackgroundColor
        field.layer.cornerRadius = 10.0
        field.leftView = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 12.0, height: 1.0))
        field.leftViewMode = .always
        field.returnKeyType = .done
        field.addTarget(self, action: #selector(self.markChanged(_:)), for: .editingDidEnd)
        field.addTarget(self, action: #selector(self.markChanged(_:)), for: .editingDidEndOnExit)
        field.frame = CGRect(x: inset, y: y, width: self.view.bounds.width - inset * 2.0, height: 44.0)
        field.autoresizingMask = [.flexibleWidth]
        scrollView.addSubview(field)
        self.markField = field
        y += 44.0 + 8.0

        let hint = UILabel()
        hint.text = "Показывается перед временем у сохранённого удалённого сообщения"
        hint.font = UIFont.systemFont(ofSize: 13.0)
        hint.textColor = presentationData.theme.list.itemSecondaryTextColor
        hint.numberOfLines = 0
        hint.frame = CGRect(x: inset, y: y, width: self.view.bounds.width - inset * 2.0, height: 34.0)
        hint.autoresizingMask = [.flexibleWidth]
        scrollView.addSubview(hint)
        y += 34.0 + 16.0

        scrollView.contentSize = CGSize(width: self.view.bounds.width, height: y + 40.0)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)

        if let scrollView = self.scrollView {
            scrollView.frame = CGRect(origin: CGPoint(), size: layout.size)
            scrollView.contentSize = CGSize(width: layout.size.width, height: max(scrollView.contentSize.height, layout.size.height + 1.0))
        }
        if let markField = self.markField {
            markField.frame = CGRect(x: 16.0, y: markField.frame.minY, width: layout.size.width - 32.0, height: 44.0)
        }
    }

    private func addSection(title: String, scrollView: UIScrollView, y: CGFloat, inset: CGFloat, presentationData: PresentationData) -> CGFloat {
        let label = UILabel()
        label.text = title
        label.font = UIFont.systemFont(ofSize: 13.0, weight: .regular)
        label.textColor = presentationData.theme.list.itemSecondaryTextColor
        label.frame = CGRect(x: inset, y: y, width: scrollView.bounds.width - inset * 2.0, height: 18.0)
        scrollView.addSubview(label)
        return y + 18.0 + 6.0
    }

    private func addRow(title: String, detail: String, scrollView: UIScrollView, y: inout CGFloat, inset: CGFloat, presentationData: PresentationData, isOn: Bool, action: Selector) -> UISwitch {
        let container = UIView()
        container.backgroundColor = presentationData.theme.list.itemBlocksBackgroundColor
        container.layer.cornerRadius = 10.0
        container.frame = CGRect(x: inset, y: y, width: scrollView.bounds.width - inset * 2.0, height: 62.0)
        container.autoresizingMask = [.flexibleWidth]
        scrollView.addSubview(container)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.systemFont(ofSize: 17.0)
        titleLabel.textColor = presentationData.theme.list.itemPrimaryTextColor
        titleLabel.frame = CGRect(x: 12.0, y: 10.0, width: container.bounds.width - 24.0 - 60.0, height: 22.0)
        container.addSubview(titleLabel)

        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = UIFont.systemFont(ofSize: 13.0)
        detailLabel.textColor = presentationData.theme.list.itemSecondaryTextColor
        detailLabel.numberOfLines = 0
        detailLabel.frame = CGRect(x: 12.0, y: 32.0, width: container.bounds.width - 24.0 - 60.0, height: 24.0)
        container.addSubview(detailLabel)

        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.onTintColor = presentationData.theme.list.itemAccentColor
        toggle.addTarget(self, action: action, for: .valueChanged)
        toggle.frame = CGRect(x: container.bounds.width - 12.0 - 51.0, y: 16.0, width: 51.0, height: 31.0)
        toggle.autoresizingMask = [.flexibleLeftMargin]
        container.addSubview(toggle)

        y += 62.0 + 8.0
        return toggle
    }

    @objc private func keepDeletedChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: ayuKeepDeletedKey)
    }

    @objc private func fakePremiumChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: ayuFakePremiumKey)
    }

    @objc private func forwardCopyChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: ayuForwardCopyKey)
    }

    @objc private func ghostChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: ayuGhostModeKey)
    }

    @objc private func markChanged(_ sender: UITextField) {
        let value = sender.text ?? ""
        UserDefaults.standard.set(value.isEmpty ? "🗑" : value, forKey: ayuDeletedMarkKey)
    }
}
