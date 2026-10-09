// KeepAwake 核心层：只读系统事实 + 纯函数判定。
//
// 为什么单独一层：UI 和特权命令都是副作用，一旦混进来就没法测试了。
// 这一层只做两件事 —— 把系统状态读出来；把「什么时候该自动动手」写成摆在明面上的规则。
// 它被两个目标同时编译：KeepAwake.app（Sources/App/main.swift）和 Tests（见 scripts/run-tests.sh）。

import Foundation
import IOKit
import IOKit.ps

// MARK: - 事实
//
// 这些字段全部来自 IOPMrootDomain，读取不需要 root。
// 实测（macOS 26.6.2 / Mac15,13）：SleepDisabled / AppleClamshellState /
// AppleClamshellCausesSleep / Last Sleep Reason 都在这个节点上。

struct PowerFacts {
    var sleepDisabled: Bool?          // 合盖保活是否开着（= pmset 的 SleepDisabled）
    var clamshellState: Bool?         // 盖子是否合上
    var clamshellCausesSleep: Bool?   // 当前配置下合盖是否会睡（接上外显时会变 No）
    var lastSleepReason: String?
}

struct BatteryFacts {
    var percent: Int?
    var onAC: Bool
}

enum ThermalLevel: Int {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    var label: String {
        switch self {
        case .nominal: return "正常"
        case .fair: return "偏高"
        case .serious: return "serious"
        case .critical: return "critical"
        }
    }
}

func thermalLevel(from state: ProcessInfo.ThermalState) -> ThermalLevel {
    switch state {
    case .nominal: return .nominal
    case .fair: return .fair
    case .serious: return .serious
    case .critical: return .critical
    @unknown default: return .nominal
    }
}

// MARK: - 读取

private func readRootDomainProperty(_ key: String) -> CFTypeRef? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

/// 一次读全顶栏要显示、守护要判断的系统事实。
func readPowerFacts() -> PowerFacts {
    var facts = PowerFacts()
    facts.sleepDisabled = (readRootDomainProperty("SleepDisabled") as? NSNumber)?.boolValue
    facts.clamshellState = (readRootDomainProperty("AppleClamshellState") as? NSNumber)?.boolValue
    facts.clamshellCausesSleep = (readRootDomainProperty("AppleClamshellCausesSleep") as? NSNumber)?.boolValue
    facts.lastSleepReason = readRootDomainProperty("Last Sleep Reason") as? String
    return facts
}

/// 电池与电源来源走 IOKit 的电源 API：不起子进程，所以可以放心地每 5 秒读一次。
func readBatteryFacts() -> BatteryFacts {
    var facts = BatteryFacts(percent: nil, onAC: true)
    guard let rawSnapshot = IOPSCopyPowerSourcesInfo() else { return facts }
    let snapshot = rawSnapshot.takeRetainedValue()
    guard let rawList = IOPSCopyPowerSourcesList(snapshot) else { return facts }
    // CFArray / CFDictionary 都是无条件桥接过来的；写成 as? 只会换来两条「永远成立」的警告。
    let list = rawList.takeRetainedValue() as [AnyObject]

    for source in list {
        guard let rawDescription = IOPSGetPowerSourceDescription(snapshot, source) else { continue }
        let description = rawDescription.takeUnretainedValue() as NSDictionary
        if let capacity = description[kIOPSCurrentCapacityKey] as? Int { facts.percent = capacity }
        if let state = description[kIOPSPowerSourceStateKey] as? String {
            facts.onAC = (state == kIOPSACPowerValue)
        }
    }
    return facts
}

// MARK: - 守护
//
// 定下的规则：热压力升到 serious 自动关、离电且电量低于 20% 自动关。
// 「拔掉电源就关」被明确否决了 —— 所以这里不把 onAC 本身当条件。

enum GuardReason: String, CaseIterable {
    case thermal = "热压力过高"
    case lowBattery = "电量过低"
}

struct GuardInput {
    var thermal: ThermalLevel
    var battery: BatteryFacts
    var lowBatteryThreshold: Int = 20
    var thermalGuardEnabled: Bool = true
    var batteryGuardEnabled: Bool = true
}

/// 返回第一条命中的守护规则，nil 表示不干预。
/// 纯函数：它只回答「该不该自动关掉」，不负责怎么关。
func evaluateGuards(_ input: GuardInput) -> GuardReason? {
    if input.thermalGuardEnabled, input.thermal == .serious || input.thermal == .critical {
        return .thermal
    }
    if input.batteryGuardEnabled, !input.battery.onAC,
       let percent = input.battery.percent, percent < input.lowBatteryThreshold {
        return .lowBattery
    }
    return nil
}

// MARK: - 意图 vs 系统的实际
//
// disablesleep 是全局粘性开关，谁都能改它（包括 launchd 里别的脚本、命令行、系统自己）。
// 原则：只在能确信是「系统重置」时才补回来，其余一律跟随系统 —— 不跟使用者抢方向盘。

enum Divergence {
    case none
    case powerdReset   // 我们想开、实际是关的，而且电源来源刚变过 → 补回来
    case externalOff   // 其余不一致 → 跟随实际状态
}

func classifyDivergence(intendedOn: Bool, actualOn: Bool, powerSourceJustChanged: Bool) -> Divergence {
    if intendedOn == actualOn { return .none }
    if intendedOn && !actualOn { return powerSourceJustChanged ? .powerdReset : .externalOff }
    return .externalOff
}

// MARK: - 显示用的小工具

func formatElapsed(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    if total < 60 { return "\(total) 秒" }
    if total < 3600 { return "\(total / 60) 分" }
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分"
}

func clockString(_ date: Date) -> String {
    let components = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
}
