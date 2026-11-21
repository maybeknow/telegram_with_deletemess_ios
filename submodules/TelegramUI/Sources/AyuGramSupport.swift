import Foundation
import UIKit

/// Голый экран логов для личной сборки: белый фон, системный шрифт, только текст.
///
/// Задачи, которые он решает:
/// - видеть, что происходит при запуске, ещё до появления интерфейса Telegram;
/// - пережить падение: всё пишется в файл, и при следующем запуске прошлый хвост виден сверху
///   (приложение, упавшее на старте, иначе не оставляет следов вообще);
/// - нечистоплотные исключения и сигналы перехватываются и дописываются в тот же файл.
public final class AyuOnScreenLog {
    public static let shared = AyuOnScreenLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let maxLines = 500

    private var window: UIWindow?
    private var logContainer: UIView?
    private var textView: UITextView?
    private var hideButton: UIButton?
    private var miniButton: UIButton?
    private var gateButton: UIButton?
    private var wipeButton: UIButton?
    private var didInstall = false
    private var gatePassed = false
    private var gateContinuation: (() -> Void)?

    private var fileHandle: FileHandle?
    private var signalFD: Int32 = -1
    private var pipeReadFD: Int32 = -1
    private var sceneRetryCount: Int = 0

    private init() {
    }

    private var logFileURL: URL {
        // Documents: файл виден в приложении «Файлы» (UIFileSharingEnabled), поэтому лог можно
        // достать с телефона, даже если приложение падает.
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return directory.appendingPathComponent("ayu-log.txt")
    }

    /// Ставит перехват вывода, окно с логом и обработчики падений. Вызывается первым делом
    /// в didFinishLaunching, до любой инициализации.
    public func install() {
        if self.didInstall {
            return
        }
        self.didInstall = true
        self.openLogFile()
        self.installCrashHandlers()
        self.redirectOutput()
        self.showPreviousSessionTail()

        // Окно с логом не создаём: второе UIWindow, поднятое в didFinishLaunching раньше окна
        // приложения, перехватывает роль ключевого и приложение остаётся с чёрным экраном.
        // Лог идёт в файл (Файлы → AyuGram → ayu-log.txt), этого достаточно.
        //
        // DispatchQueue.main.async {
        //     self.createWindowIfNeeded()
        // }
        self.log("[ayu] launch \(Bundle.main.bundleIdentifier ?? "?") \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")

        // Сердцебиение: если через секунду строка не появилась, значит didFinishLaunching не отдал
        // управление (что-то блокирует) или процесс умер раньше.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let scenes = UIApplication.shared.connectedScenes.count
            AyuOnScreenLog.shared.log("[ayu] alive +1s, scenes=\(scenes)")
        }
        // Экран логов сам убирается через 15 секунд, чтобы не закрывать приложение; вернуть — кнопка "log".
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
            self.setLogVisible(false)
        }
    }

    // MARK: - Файл

    private func openLogFile() {
        let url = self.logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.fileHandle = try? FileHandle(forWritingTo: url)
        self.fileHandle?.seekToEndOfFile()
        self.signalFD = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    }

    private func showPreviousSessionTail() {
        guard let data = try? Data(contentsOf: self.logFileURL), !data.isEmpty else {
            return
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n").suffix(60)
        if lines.isEmpty {
            return
        }
        self.lock.lock()
        self.lines.append("=== прошлый запуск ===")
        for line in lines {
            self.lines.append(String(line))
        }
        self.lines.append("=== текущий запуск ===")
        self.lock.unlock()
    }

    // MARK: - Вывод

    private func redirectOutput() {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            return
        }
        dup2(fds[1], STDOUT_FILENO)
        dup2(fds[1], STDERR_FILENO)
        close(fds[1])

        let readFD = fds[0]
        self.pipeReadFD = readFD
        let queue = DispatchQueue(label: "AyuGram.log.read")
        queue.async {
            var buffer = [UInt8](repeating: 0, count: 8192)
            var pending = Data()
            while true {
                let count = read(readFD, &buffer, buffer.count)
                if count <= 0 {
                    break
                }
                pending.append(contentsOf: buffer[0 ..< count])
                while let newlineIndex = pending.firstIndex(of: 0x0A) {
                    let lineData = pending[0 ..< newlineIndex]
                    pending.removeSubrange(0 ... newlineIndex)
                    if let text = String(data: lineData, encoding: .utf8) {
                        AyuOnScreenLog.shared.append(text)
                    }
                }
            }
        }
    }

    public func log(_ message: String) {
        self.append(message)
    }

    private func append(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
            return
        }
        self.lock.lock()
        self.lines.append(line)
        if self.lines.count > self.maxLines {
            self.lines.removeFirst(self.lines.count - self.maxLines)
        }
        let text = self.lines.joined(separator: "\n")
        self.lock.unlock()

        self.fileHandle?.write(Data((line + "\n").utf8))

        DispatchQueue.main.async {
            if let textView = self.textView {
                textView.text = text
                let end = NSRange(location: (text as NSString).length, length: 0)
                textView.scrollRangeToVisible(end)
            }
        }
    }

    // MARK: - Обработчики падений

    private func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            let text = "\n[ayu] UNCAUGHT \(exception.name.rawValue): \(exception.reason ?? "?")\n" + exception.callStackSymbols.joined(separator: "\n") + "\n"
            AyuOnScreenLog.shared.writeRaw(text)
        }
        for sig in [SIGABRT, SIGSEGV, SIGILL, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig) { received in
                let text = "[ayu] SIGNAL \(received)\n"
                AyuOnScreenLog.shared.writeSignal(text)
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    private func writeRaw(_ text: String) {
        self.fileHandle?.write(Data(text.utf8))
    }

    private func writeSignal(_ text: String) {
        // Обработчик сигнала срабатывает раньше, чем фоновый читатель успевает забрать из канала
        // уже записанное сообщение Swift ("Fatal error: ..."), поэтому сначала сливаем канал в файл:
        // read/write — async-signal-safe, в отличие от всего остального.
        let pipeFD = self.pipeReadFD
        if pipeFD >= 0 {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(pipeFD, &buffer, buffer.count)
                if count <= 0 {
                    break
                }
                if self.signalFD >= 0 {
                    _ = write(self.signalFD, buffer, count)
                }
            }
        }
        let fd = self.signalFD
        guard fd >= 0 else {
            return
        }
        // Стек прямо из обработчика сигнала: backtrace_symbols_fd не выделяет память и пишет в fd,
        // поэтому переживает трап. Имена модулей и смещения видно даже без символизации.
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let frameCount = frames.withUnsafeMutableBufferPointer { buffer -> Int32 in
            return backtrace(buffer.baseAddress, Int32(buffer.count))
        }
        if frameCount > 0 {
            _ = frames.withUnsafeMutableBufferPointer { buffer -> Int32 in
                backtrace_symbols_fd(buffer.baseAddress, frameCount, fd)
                return 0
            }
        }
        text.withCString { pointer in
            _ = write(fd, pointer, strlen(pointer))
        }
    }

    // MARK: - Окно

    private func createWindowIfNeeded() {
        guard self.window == nil else {
            return
        }
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            // Сцена подключается после didFinishLaunching — ждём её несколько кадров, но не бесконечно.
            if self.sceneRetryCount < 60 {
                self.sceneRetryCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.createWindowIfNeeded()
                }
            }
            return
        }
        window.windowLevel = UIWindow.Level.alert + 100
        window.backgroundColor = .clear

        let root = AyuPassthroughViewController()
        root.view.backgroundColor = .clear
        window.rootViewController = root

        let logContainer = UIView(frame: root.view.bounds)
        logContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        logContainer.backgroundColor = .white
        root.view.addSubview(logContainer)

        let textView = UITextView(frame: logContainer.bounds)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.backgroundColor = .white
        textView.textColor = .black
        textView.font = UIFont.systemFont(ofSize: 11.0)
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = UIEdgeInsets(top: 44.0, left: 8.0, bottom: 8.0, right: 8.0)
        logContainer.addSubview(textView)

        let hideButton = UIButton(type: .system)
        hideButton.setTitle("скрыть", for: .normal)
        hideButton.titleLabel?.font = UIFont.systemFont(ofSize: 13.0)
        hideButton.frame = CGRect(x: 8.0, y: 8.0, width: 80.0, height: 30.0)
        hideButton.addTarget(self, action: #selector(self.hideTapped), for: .touchUpInside)
        logContainer.addSubview(hideButton)

        // Кнопка возврата лога: видна всегда, поверх приложения, но маленькая и не мешает.
        let miniButton = UIButton(type: .system)
        miniButton.setTitle("log", for: .normal)
        miniButton.titleLabel?.font = UIFont.systemFont(ofSize: 11.0)
        miniButton.setTitleColor(.white, for: .normal)
        miniButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        miniButton.layer.cornerRadius = 8.0
        miniButton.frame = CGRect(x: root.view.bounds.width - 52.0, y: 8.0, width: 44.0, height: 24.0)
        miniButton.autoresizingMask = [.flexibleLeftMargin]
        miniButton.addTarget(self, action: #selector(self.miniTapped), for: .touchUpInside)
        root.view.addSubview(miniButton)

        self.window = window
        self.logContainer = logContainer
        self.textView = textView
        self.hideButton = hideButton
        self.miniButton = miniButton

        self.lock.lock()
        let text = self.lines.joined(separator: "\n")
        self.lock.unlock()
        textView.text = text

        window.isHidden = false
    }

    private func setLogVisible(_ visible: Bool) {
        self.logContainer?.isHidden = !visible
    }

    @objc private func hideTapped() {
        self.setLogVisible(false)
    }

    @objc private func miniTapped() {
        self.setLogVisible(true)
    }

    /// Приостанавливает запуск до нажатия "Запустить Telegram": приложение падает на старте
    /// мгновенно, поэтому прочитать прошлый лог иначе невозможно. Возвращает true, если запуск
    /// отложен; continuation вызовется по нажатию (и повторно вызовет didFinishLaunching).
    public func waitForGate(_ continuation: @escaping () -> Void) -> Bool {
        if self.gatePassed {
            return false
        }
        self.gateContinuation = continuation
        DispatchQueue.main.async {
            self.showGateButton()
        }
        return true
    }

    private func showGateButton() {
        self.setLogVisible(true)
        guard let container = self.logContainer, self.gateButton == nil else {
            return
        }
        let button = UIButton(type: .system)
        button.setTitle("Запустить Telegram", for: .normal)
        button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17.0)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.systemBlue
        button.layer.cornerRadius = 10.0
        button.frame = CGRect(x: 20.0, y: container.bounds.height - 132.0, width: container.bounds.width - 40.0, height: 50.0)
        button.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        button.addTarget(self, action: #selector(self.gateTapped), for: .touchUpInside)
        container.addSubview(button)
        self.gateButton = button

        // Второй путь: стереть данные и запуститься с чистой базой. База уже могла остаться
        // недописанной после предыдущих падений, отсюда "no such table: t19" и трап при старте.
        let wipeButton = UIButton(type: .system)
        wipeButton.setTitle("Стереть данные и запустить", for: .normal)
        wipeButton.titleLabel?.font = UIFont.systemFont(ofSize: 15.0)
        wipeButton.setTitleColor(.white, for: .normal)
        wipeButton.backgroundColor = UIColor.systemRed
        wipeButton.layer.cornerRadius = 10.0
        wipeButton.frame = CGRect(x: 20.0, y: container.bounds.height - 74.0, width: container.bounds.width - 40.0, height: 44.0)
        wipeButton.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        wipeButton.addTarget(self, action: #selector(self.wipeTapped), for: .touchUpInside)
        container.addSubview(wipeButton)
        self.wipeButton = wipeButton
    }

    @objc private func gateTapped() {
        self.gatePassed = true
        self.log("[ayu] gate tapped, starting")
        self.gateButton?.removeFromSuperview()
        self.gateButton = nil
        self.wipeButton?.removeFromSuperview()
        self.wipeButton = nil
        self.setLogVisible(false)
        let continuation = self.gateContinuation
        self.gateContinuation = nil
        continuation?()
    }

    @objc private func wipeTapped() {
        let removed = AyuStorageReset.wipe()
        self.log("[ayu] storage wiped: \(removed)")
        self.gateTapped()
    }
}

/// Стирание данных приложения: база Postbox и кэши. Нужно, когда после падений на старте
/// в контейнере остаётся недописанная база (симптом — "no such table" в логе).
enum AyuStorageReset {
    static func wipe() -> String {
        let fileManager = FileManager.default
        var removedPaths: [String] = []
        var didFail = false

        var roots: [URL] = []
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(applicationSupport.appendingPathComponent("telegram-data"))
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(caches)
        }

        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else {
                continue
            }
            do {
                try fileManager.removeItem(at: root)
                removedPaths.append(root.lastPathComponent)
            } catch {
                didFail = true
            }
        }
        return didFail ? "partial (\(removedPaths.joined(separator: ", ")))" : removedPaths.joined(separator: ", ")
    }
}

/// Прозрачная для нажатий обёртка: окно лога висит поверх приложения, но не должно перехватывать
/// тапы вне своих панелей — иначе интерфейс под ним перестаёт нажиматься.
private final class AyuPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        return result === self ? nil : result
    }
}

private final class AyuPassthroughViewController: UIViewController {
    override func loadView() {
        self.view = AyuPassthroughView()
    }
}
