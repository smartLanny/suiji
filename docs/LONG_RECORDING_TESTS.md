# 全天录音真机验证

目标是确认录音实际覆盖、分段可读、断连后可补传与可接受的电量变化。计时在走、索引显示 recording 或接口返回成功，均不能单独证明连续录到了声音。

## 当前基础

Watch 必须使用 `UIBackgroundModes = [audio]`。之前错误地把 audio 写在 `WKBackgroundModes`；生成器与实际 plist 已一起修正，回归测试检查重新生成后不会恢复错误字段。Apple 明确 watchOS 可在前台开始录音后继续在后台录制，但这不保证我们的 5 分钟停止/重建录音器没有间隙。[Apple 录音 category](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record) · [UIBackgroundModes](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/iPhoneOSKeys.html#//apple_ref/doc/plist/info/UIBackgroundModes)

## 自动化边界

App 可以在本机自动采集分段事件、录音器状态、低频电量、场景变化、WatchConnectivity 状态；Mac 在测试结束后一次取回数据，生成离线报告。不需要人在旁边盯计时，也不需要 Mac 持续连着设备拉取状态。

真实垂腕、戴在手上、按表冠退到表盘、移除充电器、使配对链路实际断开仍需安排。模拟器不能替代这些条件。`isLuminanceReduced` 不是“屏幕完全熄灭”，`WCSession.isReachable == false` 也不等于蓝牙/Wi-Fi 物理断开；报告保留这两个区别。

使用 Release 构建测试续航，并脱离 debugger 与实时屏幕镜像。开发连接和频繁唤屏会干扰结果。仅用 `devicectl` 启动不会自动附加 LLDB；不要带 `--console`、`--start-stopped`，也不要在测试中重新安装 App。[Apple 测试 Release 构建](https://developer.apple.com/documentation/xcode/testing-a-release-build)

## 一次开启有界诊断

默认不采样、不额外写文件。只有显式传入 `SUIJI_DIAGNOSTICS_MINUTES=1...1440` 才启用；不自动打开麦克风、不改变录音策略。启动 App 前应确认没有正在录音的旧进程，不能为套用参数终止进行中的录音。

```sh
xcrun devicectl device process launch \
  --device '<WATCH_DEVICE_ID>' \
  --environment-variables '{"SUIJI_DIAGNOSTICS_MINUTES":"120"}' \
  com.lann.suiji.watchkitapp
```

用户在前台轻点 Bot 开始；参数只控制诊断期限。第一条样本来自约 1 秒后实际调度的定时器，随后每 60 秒最多一条。样本和事件合计最多 1600 条；期限或上限到达时停止采样，**不会停止用户录音**。若进程挂起/退出，诊断不虚构中间心跳；结束状态也可能来不及写入。下一次显式启用会替换上一轮诊断，先取回旧报告再开下一轮。

日志在 `Library/Application Support/Suiji/capture-diagnostics.json`。内容包括真实 `recorder.currentTime/isRecording`、逻辑录音状态、估计计时、当前分段、分段事件、场景/亮度降低状态、电池与充电状态、待传数量。未知量写 null，不把未知电量当 0。诊断期间临时开启电池监测，结束时恢复；编码和原子写盘在串行后台队列中执行，待写快照合并为最新一份，不在下一段启动前等待磁盘。

不记录录音内容、转写、密钥、联系人或设备序列号。原始诊断和索引仍可能包含记录 ID 与时间，只保留在本机；不要提交 Git。

## 取回与汇总

```sh
python3 scripts/capture_soak.py snapshot \
  --device '<WATCH_DEVICE_ID>' \
  --bundle-id com.lann.suiji.watchkitapp \
  --out /tmp/suiji-soak/watch-after.json

python3 scripts/capture_soak.py report \
  --snapshot /tmp/suiji-soak/watch-after.json \
  --out /tmp/suiji-soak/watch-report.md \
  --label '退回表盘，用户自述' \
  --since '2026-10-13T09:00:00+08:00'
```

时间替换为本轮真实开始时间；不提供 `--since` 时，优先采用诊断的开始时间，并以 completedAt（缺省时 deadline）作为终点；没有诊断则明确标为全部历史记录。显式 `--since` 保持只设下界的语义，报告展示无终点。按片段起点纳入，跨终点片段整段计入并单独标记；整段时长不冒充窗口内已完整覆盖的时长。输出必须放在工程外，已有文件不覆盖。Watch 需指定 Watch bundle；默认 bundle 用于读取手机。没有开启诊断时可用 `--skip-diagnostics` 只读索引。

快照含原始索引，应只留本机；报告仅输出汇总，去除录音 ID、转写、音频路径和设备 ID。报告不包含音频，因此不会宣称文件已解码。必要时在本机另取回指定已完成片段，用 ffprobe / 完整解码核对实际音频时长、采样率、声道及错误；完成后清理本机测试副本，不删除设备原声。

## 测试顺序

| 场景 | 建议时长与操作 | 通过证据 |
| --- | --- | --- |
| 基础轮转 | 前台开始，连续 12 分钟 | 至少两段完成、一段后续录音；完整音频能解码，分段起点与实际音频时长可核对 |
| 垂腕变暗 | App 留在前台，正常佩戴垂腕 12 分钟 | 用户操作时间、亮度降低/场景样本、真实录音器与分段文件；不把 AOD 变暗称为完全息屏 |
| 返回表盘 | 录音开始后按 Crown，12 分钟后返回 | background 事件、至少两次轮转，返回后仍在录制；先后片段均有实际音频 |
| 与手机断连 | 在确实失去配对传输条件后录制 12 分钟，不解除配对；之后恢复 | 断开条件由操作记录证明；Watch 保存完备，恢复后手机同 ID 唯一导入，标记相同，ACK 后才释放副本 |
| 耗电 | 正常佩戴、未充电，录音与不录音各做约 2 小时；其余使用尽量相近 | 起止电量、有效时段、充电状态及设备条件；报告观测差值和百分点/小时，不从几分钟推算全天 |
| 日常长用 | 基础通过后再做 8–12 小时，最后扩到 24 小时含实际充电窗口 | 持续覆盖与明确中断区间、每段可读、重连补传、实际充电需求 |

飞行模式可能保留无线开关，不能只看到飞机图标就认定断连。测试时记录实际操作，必要时确认 Watch 的 Wi-Fi/蓝牙均关闭，再恢复原状态；不用解除配对、重置设备或关闭 Mac 网络来代替。

## 结果口径

- 区分录音时长、记录覆盖时间窗和真实文件音频时长。索引中的 duration 不等同解码证据。
- 相邻分段开始时间差减去上一段音频时长，只是候选边界间隙；需要稳定声源或可辨认时间信号才能测定是否漏掉声音，不预先承诺无缝。
- 少了诊断样本不直接判停止；采样显示 recorder=false 也只代表该时刻，应结合中断与文件事件。
- 充电/未知充电状态混入时不计算耗电速率；不足 60 分钟只报起止电量与净变化。两个小时仍是短期观测，不能当 24 小时保证。
- 当前采样和部分报告已经实现，完整 S9 断连与电量试验尚未通过。真实设备进展统一写入 [验收记录](ACCEPTANCE.md)。
