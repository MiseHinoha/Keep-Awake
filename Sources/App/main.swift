// KeepAwake —— 顶栏上的「合盖保活」开关。
//
// 它存在的理由不是「少打一条命令」，而是命令行给不了的三件事：
//   1. 状态可见：disablesleep 是全局粘性开关，系统里没有任何指示器，忘关也不会有人告诉你；
//   2. 自动回收：热压力升到 serious、或离电后电量见底时，自己关掉；
//   3. 自愈 + 同步：Apple Silicon 换电源时 powerd 可能把它重置，我们看到
//      「电源刚变过 + 标志被清」就补回来；其余不一致一律跟随系统（见 Core/classifyDivergence）。
//
// 切换需要 root，因此走 /usr/local/sbin/keepawake-pmset（免密白名单，见 scripts/install-helper.sh）；
// 没装授权时回退到系统授权框，装好之前也能用。

import AppKit
import Foundation

private let helperPath = "/usr/local/sbin/keepawake-pmset"

// MARK: - 日志

enum Log {
    static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/KeepAwake.log")

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - 特权助手

enum HelperResult {
    case success
    case missingHelper
    case failure(String)
}

func shell(_ launchPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (127, "无法执行 \(launchPath)：\(error.localizedDescription)")
    }
    // 先读完再 wait：输出若超过管道缓冲，先等就会互相卡死。
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

enum HelperRunner {
    static func run(_ verb: String) -> HelperResult {
        guard FileManager.default.fileExists(atPath: helperPath) else { return .missingHelper }

        // 首选：免密白名单（装过 sudoers 之后走的就是这条，零打扰）
        let direct = shell("/usr/bin/sudo", ["-n", helperPath, verb])
        if direct.status == 0 { return .success }

        // 回退：让系统弹一次授权框 —— 还没装白名单时也能用，代价是每次要输密码
        let script = "do shell script \"\(helperPath) \(verb)\" with administrator privileges"
        let prompt = shell("/usr/bin/osascript", ["-e", script])
        if prompt.status == 0 { return .success }

        let message = prompt.output.isEmpty ? direct.output : prompt.output
        return .failure(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - 顶栏

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    private var desiredOn: Bool
    private var enabledAt: Date?
    private var autoOffNote: String?

    private var facts = PowerFacts()
    // 两个状态各自的图标各建一次，之后一直复用同一个实例。
    // 原来每次 refresh 都新建一个 NSImage，那会让按钮重新排版：
    // 系统切换桌面后重合成菜单栏时，抓到的可能正是这一下「尺寸不同的中间帧」，
    // 看起来就是图标先放大又缩回。复用实例之后重画不会改变版面。
    // 画法本身在 StatusIcon.swift（两态共用一张固定画布，位置才对得上）。
    private lazy var iconOn: NSImage? = StatusIcon.make(symbol: "cup.and.saucer.fill", description: "合盖保活：已开启")
    private lazy var iconOff: NSImage? = StatusIcon.make(symbol: "moon.zzz", description: "合盖保活：已关闭")
    private var renderedOn: Bool?
    private var battery = BatteryFacts(percent: nil, onAC: true)
    private var thermal: ThermalLevel = .nominal
    private var lastOnAC: Bool?
    private var powerChangedAt: Date?

    override init() {
        desiredOn = UserDefaults.standard.bool(forKey: "desiredOn")
        enabledAt = UserDefaults.standard.object(forKey: "enabledAt") as? Date
        autoOffNote = UserDefaults.standard.string(forKey: "autoOffNote")
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = "合盖保活（KeepAwake）"

        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // 唤醒、热状态变化都立刻重读一次，不等下一个 5 秒
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshFromNotification), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshFromNotification), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)

        // 系统会在这几个时刻把顶栏重新合成一遍：换桌面（Space）、屏幕参数变化、从睡眠醒来。
        // 重新合成时它可能先端出上一次的画面 —— 图标会「闪回」先前的状态或大小，
        // 一直到我们自己下一次重画才恢复。这些地方主动把当前这一帧再写一次，
        // 把那个空窗期从「下一个 5 秒」压到一帧以内。
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        Log.write("启动：意图=\(desiredOn ? "开" : "关") 实际=\(facts.sleepDisabled.map { $0 ? "开" : "关" } ?? "未知")")
    }

    @objc private func refreshFromNotification() {
        refresh()
        reassertStatusItem()
    }

    @objc private func spaceChanged() {
        reassertStatusItem()
    }

    @objc private func screenParametersChanged() {
        reassertStatusItem()
    }

    /// 系统重合成顶栏的瞬间把当前这一帧再写一遍；换桌面还带着半秒左右的动画，
    /// 动画落定后再各补一笔，免得它把动画中途抓到的旧帧留在屏上。
    ///
    /// 这里**不写日志**：它只是重画，不是状态变化。日志只记状态相关的事
    /// （启动、电源来源变化、手动切换、外部改动、守护触发）—— 换一次桌面刷一行太吵。
    private func reassertStatusItem() {
        writeStatusItemNow()
        scheduleReassert(after: 0.4)
        scheduleReassert(after: 1.0)
    }

    private func scheduleReassert(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.writeStatusItemNow()
        }
    }

    /// 只用缓存好的那个 NSImage 实例（尺寸不会变），再手工标脏 ——
    /// 「赋同一个实例」AppKit 可能认为是空操作，不标脏就不会重画，补写也就白补。
    private func writeStatusItemNow() {
        updateStatusItem(force: true)
        statusItem.button?.needsDisplay = true
    }

    // MARK: 状态读取与守护

    private func refresh() {
        let newFacts = readPowerFacts()
        let newBattery = readBatteryFacts()
        thermal = thermalLevel(from: ProcessInfo.processInfo.thermalState)

        // 电源来源变化是已知的「标志被 powerd 重置」触发器，记一个 30 秒的时间窗。
        if let previous = lastOnAC, previous != newBattery.onAC {
            powerChangedAt = Date()
            Log.write("电源来源变化：\(previous ? "接通电源" : "使用电池") → \(newBattery.onAC ? "接通电源" : "使用电池")")
        }
        lastOnAC = newBattery.onAC
        facts = newFacts
        battery = newBattery

        reconcile()
        enforceGuards()
        updateStatusItem()
    }

    private func reconcile() {
        guard let actual = facts.sleepDisabled else { return }
        let powerJustChanged = powerChangedAt.map { Date().timeIntervalSince($0) < 30 } ?? false

        switch classifyDivergence(intendedOn: desiredOn, actualOn: actual, powerSourceJustChanged: powerJustChanged) {
        case .none:
            return
        case .powerdReset:
            Log.write("检测到标志被重置（电源刚变过），自动补回")
            if case .success = HelperRunner.run("on") {
                autoOffNote = nil
            } else {
                desiredOn = false
                enabledAt = nil
                autoOffNote = "标志被系统重置且无法自动恢复，请检查免密授权"
            }
        case .externalOff:
            Log.write("外部改动：跟随为 \(actual ? "开" : "关")")
            desiredOn = actual
            enabledAt = actual ? (enabledAt ?? Date()) : nil
        }
        persist()
    }

    private func enforceGuards() {
        guard desiredOn else { return }
        guard let reason = evaluateGuards(GuardInput(thermal: thermal, battery: battery)) else { return }

        Log.write("守护触发（\(reason.rawValue)）：自动关闭合盖保活")
        if case .success = HelperRunner.run("off") {
            desiredOn = false
            enabledAt = nil
            autoOffNote = "已于 \(clockString(Date())) 因\(reason.rawValue)自动关闭"
            persist()
        }
    }

    // MARK: 切换

    @objc private func toggleFromMenu() {
        setEnabled(!desiredOn, reason: "手动")
    }

    private func setEnabled(_ on: Bool, reason: String) {
        switch HelperRunner.run(on ? "on" : "off") {
        case .success:
            desiredOn = on
            enabledAt = on ? Date() : nil
            autoOffNote = nil
            Log.write("\(reason)切换为\(on ? "开启" : "关闭")")
        case .missingHelper:
            showHelperInfo()
            return
        case .failure(let message):
            presentFailure(message)
            return
        }
        persist()
        refresh()
    }

    private func persist() {
        defaults.set(desiredOn, forKey: "desiredOn")
        if let enabledAt {
            defaults.set(enabledAt, forKey: "enabledAt")
        } else {
            defaults.removeObject(forKey: "enabledAt")
        }
        if let autoOffNote {
            defaults.set(autoOffNote, forKey: "autoOffNote")
        } else {
            defaults.removeObject(forKey: "autoOffNote")
        }
    }

    // MARK: 顶栏外观

    private func updateStatusItem(force: Bool = false) {
        guard let button = statusItem.button else { return }
        if force || renderedOn != desiredOn {
            button.image = desiredOn ? iconOn : iconOff
            // 顶栏只留图标：状态靠「换图标 + 橙色」表达，菜单栏里不占文字宽度。
            // 仍然显式清空标题 —— 否则按钮会留住旧标题，状态就看不准了。
            button.title = ""
            button.imagePosition = .imageOnly
            button.contentTintColor = desiredOn ? .systemOrange : nil
            renderedOn = desiredOn
        }
        button.toolTip = desiredOn ? "合盖保活：已开启" : "合盖保活：已关闭"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        addInfo(desiredOn ? "合盖保活：已开启" : "合盖保活：已关闭")
        if desiredOn, let since = enabledAt {
            addInfo("已保活 \(formatElapsed(Date().timeIntervalSince(since)))")
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: desiredOn ? "关闭合盖保活" : "开启合盖保活",
                                action: #selector(toggleFromMenu), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())
        let lid = facts.clamshellState == true ? "已合上" : "打开"
        let lidExtra = facts.clamshellCausesSleep == false ? "（当前配置合盖不会睡）" : ""
        addInfo("盖子：\(lid)\(lidExtra)")
        let power = battery.onAC ? "接通电源" : "使用电池"
        addInfo("电源：\(power)" + (battery.percent.map { " · \($0)%" } ?? ""))
        addInfo("热压力：\(thermal.label)")
        if let lastSleep = facts.lastSleepReason {
            addInfo("上次睡眠原因：\(lastSleep)")
        }
        if let note = autoOffNote {
            addInfo(note)
        }

        if !FileManager.default.fileExists(atPath: helperPath) {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "尚未安装免密助手 —— 点此查看安装命令",
                                  action: #selector(showHelperInfo), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let logItem = NSMenuItem(title: "打开日志", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addInfo(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    // MARK: 弹窗（都是使用者主动点开的，所以允许抢焦点）

    @objc private func showHelperInfo() {
        let command = "sudo sh \"\(Bundle.main.bundlePath)/Contents/Resources/install-helper.sh\""
        let alert = NSAlert()
        alert.messageText = "还差一次性授权"
        alert.informativeText = """
        合盖保活要改系统电源设置，只有 root 能做。运行下面这条命令，装一个只放行 on / off 两个参数的免密助手：

        \(command)

        装完之后，这个开关就是点一下的事，不再要密码。
        """
        alert.addButton(withTitle: "复制命令")
        alert.addButton(withTitle: "关闭")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)
        }
    }

    private func presentFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "切换失败"
        alert.informativeText = message.isEmpty ? "免密助手返回了非零退出码，详见日志。" : message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.url)
    }
}

// MARK: - 入口

let bundleID = Bundle.main.bundleIdentifier ?? "io.github.misehinoha.keepawake"
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .contains(where: { $0.processIdentifier != getpid() }) {
    // 已经有一个实例挂在顶栏上了（比如手动开的 + 登录自启的），直接退出，避免出现两个图标。
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
