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

如果 App 已经运行，直接 launch 可能沿用旧进程，参数不生效。先读回日志确认 test.startedAt 是本轮时间；仅在确认没有进行中录音时使用 `--terminate-existing` 重新启动，必要时同时传入 `--SUIJI_DIAGNOSTICS_MINUTES=120` 启动参数。参数接受不代表日志已开始，必须检查实际文件。

用户在前台轻点 Bot 开始；参数只控制诊断期限。第一条样本来自约 1 秒后实际调度的定时器，随后每 60 秒最多一条。样本和事件合计最多 1600 条；期限或上限到达时停止采样，**不会停止用户录音**。若进程挂起/退出，诊断不虚构中间心跳；结束状态也可能来不及写入。下一次显式启用会替换上一轮诊断，先取回旧报告再开下一轮。

日志在 `Library/Application Support/Suiji/capture-diagnostics.json`。内容包括实际音频进展、逻辑录音状态、计时、当前分段、分段事件、场景/亮度降低状态、电池与充电状态、待传数量。2026-10-14 起保留 `recorderCurrentTime/recorderIsRecording` 字段名，但分别来自当前文件实际写入帧数除以采样率，以及 Engine 运行且 writer 没有失败；旧快照来自 AVAudioRecorder。未知量写 null，不把未知电量当 0。诊断期间临时开启电池监测，结束时恢复；编码和原子写盘在串行后台队列中执行，待写快照合并为最新一份，不在下一段启动前等待磁盘。

两端均记录 WatchConnectivity 激活/可达状态、待传文件数及 `watchOutstandingReceiptTransfers`（当前端出站录音回执数量）。后者不包含回执内容；0 只代表当前没有待发项，不能据此认定对端已持久保存回执。收到与释放仍以 Watch 索引中的实际字段核对。主动回执核对记录 `receipt_query_started/completed/failed`，手机记录 `receipt_query_answered`，旧回执路径记录 `receipt_received`。新增阶段诊断可包含本机记录 ID，用于关联同一片段的排队、导入和确认；不含录音内容。恢复验收应核对同批 ID、手机数量和 Watch 实际音频目录，不能只看消息成功回调。

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

若手表蓝牙入口不易找到，可关闭 iPhone「设置 → 蓝牙」总开关，同时在手表设置关闭 Wi-Fi，并在蜂窝款上关闭蜂窝数据；手机 Wi-Fi/蜂窝无需关闭。手机控制中心的蓝牙按钮会保留 Apple Watch 等连接，不能代替设置中的总开关。断连图标只作辅助提示，记录真实开关操作；期间不连接调试或拉取 Watch 日志，录完后先正常保存，再恢复原开关并检验补传。[Apple 控制中心蓝牙说明](https://support.apple.com/en-us/102412) · [Watch 连接方式](https://support.apple.com/en-us/109319)

## 结果口径

- 区分录音时长、记录覆盖时间窗和真实文件音频时长。索引中的 duration 不等同解码证据。
- 相邻分段开始时间差减去上一段音频时长，只是候选边界间隙；需要稳定声源或可辨认时间信号才能测定是否漏掉声音，不预先承诺无缝。
- 少了诊断样本不直接判停止；采样显示 recorder=false 也只代表该时刻，应结合中断与文件事件。
- 报告的 `recorderClockStall` 只提示实际音频时钟不增长的疑点：同一片段、录音状态均为真，至少三次有效采样跨 120 秒以上、相邻间隔不超过 150 秒，音频时间范围不超过 0.05 秒。换段、缺值、时间倒退或采样断档会切断观察区间；前后台变化本身不触发停滞。只输出聚合，不输出片段 ID；零候选不代表连续录音通过。
- 充电/未知充电状态混入时不计算耗电速率；不足 60 分钟只报起止电量与净变化。两个小时仍是短期观测，不能当 24 小时保证。
- 当前采样和部分报告已经实现；S9 短时断连录音、恢复导入与回执释放已通过，长时耗电试验仍未通过。真实设备进展统一写入 [验收记录](ACCEPTANCE.md)。

## 分轮保存与电量窗口

每轮正常停止并保存后取回独立快照，再开始下一轮；每份报告的 `--since` 使用该轮第一段真实 `recordedAt`。这样前台准备、上一轮短录或后续充电不会混入同一快照。显式下界没有隐式终点，不要拿后续累积快照回算早一轮。

两小时电量轮建议录制约 125 分钟，并要求实际有效电量样本跨度至少 120 分钟。诊断期限要覆盖整轮（例如预留 150 分钟）；到期只停止采样，用户录音不会自动结束。若当前诊断剩余时间不够，先正常停止/保存，再从空闲状态重新开启足够长的诊断。不同测试轮的指标分别报告，不从最初安装/镜像调试时刻开始计算耗电。

## 缩短分段的故障回归

排查分段交接时，可在开启有界诊断的同次启动中传入 `--SUIJI_TEST_SEGMENT_SECONDS=60`，允许范围为 10–300 秒。只在诊断期限内影响新开始的片段；当前段按其启动时的期限收尾，诊断到期后下一段恢复默认 300 秒。此参数不会自动开录，正式五分钟回归需从空闲状态重新启动 App 并省略它。

`segment_begin.segmentDurationSeconds` 记录该段实际采用的期限；音频会话激活结果、激活/停用通知与 `progress_stalled` 用来区分启动失败和启动后不再收音。若执行中的观察连续超过 10 秒没有音频时间进展，App 保存已录部分并显示中断，不自动重开麦克风。进程被系统挂起时检测也会延后，不能把它当作保证 10 秒内提醒的后台看门狗。

短段循环通过只能缩小故障范围，仍需重复原始五分钟分段、返回表盘场景，并核对落盘音频。停止假计时的保护本身不代表续录已修复。

## 无唤醒同步的阶段定位

2026-10-13 加入有界阶段诊断；仍需显式启用，两端都开启才可关联端到端延迟。Watch 后台刷新处理先执行 `resume/enqueuePending`，再注册可能立即完成的刷新任务，避免排队发生在任务结束之后。这个顺序修正不证明此前积压的根因已经找到，也不改变 Apple 对 `transferFile` 的后台调度。

需要对应同一个本机记录 ID，核对以下事件：

1. Watch `segment_finish`、`watch_file_transfer_enqueued`：文件何时准备好、何时交给系统。
2. Watch `watch_file_transfer_did_finish_entry`：系统发送结果，不能代替手机的持久保存回执。
3. iPhone `phone_file_receive_entry`、`phone_file_import_committed`、`phone_receipt_persisted`、`phone_receipt_transfer_queued`：接收入口、文件与索引提交、确认落盘、回执入队。
4. Watch `watch_user_info_receive_entry`、`watch_phone_receipt_applied`，或主动核对的回复：确认何时真正到达与应用，最终还应检查副本释放。

回调入口在实际回调线程记录墙钟和单调时钟；诊断事件保留该入口时间，另记 `mainActorDispatchDelayMilliseconds`，不能把主线程排队时间误当系统传输延迟。事件异步持久化，突然挂起可能只保留部分证据；缺少事件不能单独证明回调没有发生。不同设备的墙钟也有误差，毫秒级结论优先使用同机单调时钟。

`watch_enqueue_batch` 区分系统队列已有、重试冷却和文件缺失；每分钟原有采样只增加文件传输进度的最小值、最大值和有进度的数量，不新增高频轮询。`watch_refresh_handler_stage`、刷新任务注册/完成/到期及重试计划/执行记录用于判断后台生命周期。默认关闭诊断时不写这些事件，也不新建采样定时器。

iPhone 同时记录场景变化，样本包含 `phoneApplicationState` 和 `phoneBackgroundRefreshStatus`，用于区分实际前后台、系统后台刷新是否可用。低电量模式会自动关闭后台刷新；这个字段是环境线索，不能单独证明 WatchConnectivity 的延迟原因，也不因为未知或 restricted 就要求用户改设置。[Apple 后台刷新状态](https://developer.apple.com/documentation/uikit/uiapplication/backgroundrefreshstatus)

实测时手机退到后台、Watch 开录后回表盘，期间不打开两端 App、不镜像或拉取 Watch。结束前先读手机持久索引，再让用户回 Watch 停止；停止后只读手机，记录系统自然到达时间。若最后需要唤醒才补齐，应明确判为无干预同步未通过，不能把最终文件齐全写成及时同步通过。一次短测只说明本轮状态，不能给出系统保证的送达上限。

## 固定声源的分段边界测量

旧采集器的 `segment_timing` 记录完成回调进入主线程的等待、关闭文件、读取时长、保存索引、激活会话与重建录音器等耗时。新持续输入路径记录 `file_begin/file_finish` 的关闭、索引和建文件耗时，以及实际帧数和采样率；不再每段重启输入。这些事件都只测处理时间，不代表第一帧/最后一帧实际收音边界。

使用 `scripts/segment_probe.py` 生成非周期参考声源，或在本机分析录音。它不会播放、开麦或上传；依赖 NumPy。参考和实际录音均放工程外，避免混入公开仓库。

```sh
python3 scripts/segment_probe.py generate --seconds 180 --out /tmp/suiji-reference.wav
python3 scripts/segment_probe.py align --reference /tmp/suiji-reference.wav \
  --captures /tmp/segment-1.wav /tmp/segment-2.wav /tmp/segment-3.wav
```

安排一次约 150 秒的录音、60 秒临时分段，手机保持后台。先播放参考声源，再开始录音；停止录音后才结束声源，确保每段开头和结尾都处于参考音轨内。用户只需放好手表并开停，中途不用盯屏。设备无需离开充电器，此轮不测耗电。保持声源位置与正常可听音量，无法识别的录音判为未知。

按真实录制顺序将手机收到的片段解码为单声道 16 kHz、16-bit PCM WAV。工具分别匹配首尾一秒锚点，低相关、周期声源歧义或不合理时钟比例均拒绝给通过结论。相邻锚点的缺失区间为正值、重复为负值；默认 20 ms 只是初始容差，不是已标定精度。退出码 0 表示边界在容差内、2 为缺失/重复、3 为无法判断、1 为输入错误。边界对齐不验证片段内部连续性。

合成测试覆盖无缺口、1.5 秒缺口、0.25 秒重叠、静音、无关噪声和周期歧义；真机声学路径、AAC 裁切与时钟漂移仍需独立验收。通过后恢复默认 300 秒分段，重复至少两次正式交接。不得仅把分段改长来宣称修复漏音。
