// KeepAwake 的断言测试。
//
// 为什么不引 XCTest：这个项目要能一条命令跑起来、零依赖，谁都能在任意终端里复核。
// 被测的是 Core 层的纯函数；唯一碰系统的是最后两条集成断言。

import Foundation

var passed = 0
var failed = 0

func expect(_ condition: Bool, _ description: String) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("✗ \(description)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ description: String) {
    if actual == expected {
        passed += 1
    } else {
        failed += 1
        print("✗ \(description)：期望 \(expected)，实际 \(actual)")
    }
}

// MARK: 守护判定

let ac = BatteryFacts(percent: 80, onAC: true)
let lowBattery = BatteryFacts(percent: 19, onAC: false)
let edgeBattery = BatteryFacts(percent: 20, onAC: false)
let unknownBattery = BatteryFacts(percent: nil, onAC: false)

expectEqual(
    evaluateGuards(GuardInput(thermal: .nominal, battery: ac)), nil,
    "一切正常时不干预")
expectEqual(
    evaluateGuards(GuardInput(thermal: .serious, battery: ac)), .thermal,
    "热压力 serious 触发")
expectEqual(
    evaluateGuards(GuardInput(thermal: .critical, battery: ac)), .thermal,
    "热压力 critical 触发")
expectEqual(
    evaluateGuards(GuardInput(thermal: .fair, battery: ac)), nil,
    "热压力 fair 不触发")
expectEqual(
    evaluateGuards(GuardInput(thermal: .nominal, battery: lowBattery)), .lowBattery,
    "离电且电量低于阈值触发")
expectEqual(
    evaluateGuards(GuardInput(thermal: .nominal, battery: edgeBattery)), nil,
    "刚好等于阈值不触发（严格小于才算）")
expectEqual(
    evaluateGuards(GuardInput(thermal: .nominal, battery: BatteryFacts(percent: 5, onAC: true))), nil,
    "接电时电量再低也不触发 —— 「拔电即关」被明确否决")
expectEqual(
    evaluateGuards(GuardInput(thermal: .nominal, battery: unknownBattery)), nil,
    "读不到电量时不猜、不关")
expectEqual(
    evaluateGuards(GuardInput(thermal: .critical, battery: ac, thermalGuardEnabled: false)), nil,
    "关闭热守护后不再触发")
expectEqual(
    evaluateGuards(GuardInput(thermal: .critical, battery: lowBattery)), .thermal,
    "两条同时命中时，热优先")

// MARK: 意图与实际的差异

expectEqual(
    classifyDivergence(intendedOn: true, actualOn: true, powerSourceJustChanged: false), .none,
    "一致时不动作")
expectEqual(
    classifyDivergence(intendedOn: true, actualOn: false, powerSourceJustChanged: true), .powerdReset,
    "电源刚变过 + 标志被清 → 判为系统重置，补回来")
expectEqual(
    classifyDivergence(intendedOn: true, actualOn: false, powerSourceJustChanged: false), .externalOff,
    "电源没变但标志被清 → 判为在别处被关掉了，跟随")
expectEqual(
    classifyDivergence(intendedOn: false, actualOn: true, powerSourceJustChanged: false), .externalOff,
    "别处打开了 → 跟随为开")

// MARK: 显示

expectEqual(formatElapsed(0), "0 秒", "0 秒显示")
expectEqual(formatElapsed(45), "45 秒", "不足一分钟按秒显示")
expectEqual(formatElapsed(125), "2 分", "不足一小时按分显示")
expectEqual(formatElapsed(3720), "1 小时 2 分", "超过一小时带分钟")
expectEqual(formatElapsed(7200), "2 小时", "整小时不带零头")
expectEqual(formatElapsed(-5), "0 秒", "负数被夹到 0")

expectEqual(thermalLevel(from: .serious), .serious, "ProcessInfo 热状态映射")
expectEqual(thermalLevel(from: .nominal), .nominal, "ProcessInfo 正常状态映射")

// MARK: 集成（只断言「读得到」，不断言具体值 —— 值会随实际使用变化）

let facts = readPowerFacts()
expect(facts.sleepDisabled != nil, "IOPMrootDomain 能读到 SleepDisabled")
expect(facts.clamshellState != nil, "IOPMrootDomain 能读到 AppleClamshellState")

let batteryFacts = readBatteryFacts()
expect(batteryFacts.percent == nil || (0...100).contains(batteryFacts.percent!), "电量读数落在 0...100 内")

print(failed == 0 ? "✓ \(passed) 项通过" : "✗ \(failed) 项失败 / \(passed) 项通过")
exit(failed == 0 ? 0 : 1)
