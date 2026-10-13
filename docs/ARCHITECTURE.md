# 原生架构

本文描述 2026-10-14 的实际实现。当前闭环是录音、本地保存、Watch 向手机同步、通用 ASR 转写、回听和原声留存；完整产品范围见 [路线图](ROADMAP.md)。持续输入新路径已通过离线写盘测试，S9 运行结果单列在验收记录，不能沿用旧录音器的真机结论。

## 模块与数据路径

| 模块 | 责任 |
| --- | --- |
| `Sources/SuijiCore` | 录音模型、文件与 manifest 持久化、留存规则、通用 ASR 客户端；通过 SwiftPM 测试 |
| `Shared/AudioCapture.swift` | AVAudioEngine 持续输入、麦克风权限、实际帧计时、中断保存、启动时恢复未完成录音 |
| `Shared/ContinuousAudioWriter.swift` | 有界串行写盘，按帧轮转 AAC 文件，有序标记、停止与草稿取消 |
| `Shared/CaptureDiagnostics.swift` | 显式开启、限时限量的本地录音诊断，不改变采集和同步 |
| `Shared/CompanionSync.swift` | WatchConnectivity 文件排队、手机落盘、应用级回执、Watch 副本释放 |
| `Shared/SessionModel.swift` | 界面状态、串行转写队列、恢复与清理、配置和 Keychain |
| `iOS` / `Watch` | 各端 SwiftUI；共用核心源码直接编译进两端 App |

```text
iPhone 麦克风 → 手机 Audio/UUID.m4a → recordings.json
Watch 麦克风 → 手表 Audio/UUID.m4a → transferFile
                                      ↓
                          手机校验并持久保存 → transferUserInfo 回执
                                      ↓                    ↓
                             手机串行 ASR 队列       Watch 删除已交付副本
                                      ↓
                           文字写入 manifest → 回听 / 更正 / 分享 / 留存清理
```

两端分别使用 App 容器内的 `Application Support/Suiji`，音频在 `Audio/`，索引为 `recordings.json`（当前版本 1）。manifest 原子写入；手机导入先复制临时文件再移动，并校验 UUID、来源、正时长和字节数。相同录音 ID 重传不会新增一条记录。当前没有 Obsidian 自动写入、云端数据库或独立备份闭环。

## 状态与回执

- 采集状态：`recording → ready`；系统中断或意外结束恢复为 `interrupted`，可读的部分仍可转写。中断后由用户重新开始录音。
- 转写状态：`pending → transcribing → completed / failed`。只有非空文字持久保存后才算完成；失败保留原声并允许重试。重启时把遗留的 `transcribing` 恢复为 `pending`；任务取消也回到待处理。
- 同步状态独立于转写。`transferFile` 排队或系统传输完成不等于手机已保存。手机完成导入与 manifest 保存后才发 `recordingReceipt`；Watch 收到回执并写入 `phoneReceivedAt` 后才释放副本。系统决定传输时机，未承诺到达时延；实际后台、离线及回执恢复结果见 [验收记录](ACCEPTANCE.md)。
- 回执恢复：Watch 在激活、回到前台、连接恢复及有积压时，主动请求手机核对记录 ID；每批至多 50 个，轮换处理，单次在途。手机只确认已持久导入、文件字节数正确的 Watch 记录，或已按留存规则清理且完整转写仍存在的记录。Watch 只接受本次所问的 ID，先持久写回执，再释放音频；未拿到确认或回执写盘失败时保留副本并继续重试。原有 `transferUserInfo` 回执路径保留。
- 发送成功后的等待：`TransferRetryLedger` 把系统传输成功与手机持久确认分开，台账编码保存到 Watch 的 UserDefaults。成功后的 5 分钟内不因 60 秒重试触发整文件重传，仍可核对回执；超时后允许恢复发送，正回执清除等待，负核对不抢先重发。每次传输带本地 attempt ID，旧尝试的迟到回调不能覆盖新尝试。5 分钟是初始恢复上限，不是系统送达保证，也不等同录音分段长度。
- Watch 后台任务先恢复排队，再注册/检查完成。系统发送回调入口同步登记未完成工作，MainActor 写入上述台账后释放登记；KVO 的空闲完成路径也检查这道门槛，避免任务提前结束。这个修正仍需要后台冷启动真机验收。
- ASR 目前使用普通 URLSession 上传，前台串行处理，申请有限的 UIKit 后台收尾时间；到期取消，下一次激活续处理。没有后台 URLSession 或 BGProcessingTask，也没有 App 被终止后持续转写的保证。

## 留存与文件保护

当前原声默认 **30 天**，设置支持 1–3650 天或一直保留；到期从 `recordedAt + 天数 × 24 小时` 计算。手机只清理已完成转写且文字非空、未显式保留、未在录音的原声；Watch 来源还必须有手机接收记录。失败、待转写片段暂缓。清理在 App 激活、转写完成或修改策略时触发，不是到点定时删除。

音频删除后保留文字、元数据和 `audioDeletedAt`，界面取消回听并显示已清理。Watch 交付副本释放与手机留存是两个步骤。已交给第三方 ASR 的临时云副本由服务协议控制，当前客户端不具备远端删除接口。

本地核心文件使用 `completeUntilFirstUserAuthentication`；API Key 使用手机 Keychain 的 `AfterFirstUnlockThisDeviceOnly`。设备重启后首次解锁前的操作仍需实机验收。这些设置不构成额外备份或端到端加密服务。

## ASR 兼容契约

配置是 `baseURL / model / language`；当前只有一个 ASR 配置，没有快转、精转和文本 AI 的独立队列。默认地址为 `https://api.openai.com/v1`，模型必须填写，语言默认 `zh`，可为空。

- `POST {baseURL}/audio/transcriptions`，完整 endpoint 也可输入，避免重复拼接；不会替任意网关自动添加 `/v1`。
- multipart 仅包含 `file`、`model`、可选 `language`；m4a MIME 为 `audio/mp4`。分块写临时上传文件，再 `upload(fromFile:)`，不把大录音整体载入内存。
- 原音频必须大于 0 且不超过 25,000,000 字节。默认请求超时 120 秒；客户端初始化可调整。超限、超时或 HTTP 失败均保留原声。
- 只接受 HTTPS；HTTP 仅允许 loopback。拒绝 URL 中的账号、查询参数、fragment 及所有重定向。非空 Key 才添加 Bearer；允许无 Key 私有网关。系统网络策略仍需对应设备验证。
- 成功契约是 HTTP 2xx 且 JSON `{"text":"非空文字"}`。HTTP 200 空结果不算完成。错误不回显服务响应正文或 Key。
- OpenAI 兼容路径不保证服务提供说话人、词级时间戳、长文件、中文质量或特定模型能力；当前只消费文字。真实服务尚未联调。

Key 只在手机设置输入和 Keychain 保存，不进 UserDefaults、Watch 同步或仓库；非秘密配置与留存设置保存在 UserDefaults。

## 记录意图与草稿取消

`Recording.intent` 与 `ClipEnvelope.intent` 支持 `note` / `journal`；旧索引或旧同步消息缺少字段时按 `note` 解码，manifest 保持版本 1。日记类型在每个分段上保留，手机导入时沿用，不依赖转写结果猜测。

`AudioCapture.canDiscardRecording` 仅在快速口述首段尚未提交时成立。`discardCurrentRecording()` 停止录音器，成功时不调用 `onSaved`，通过 store 删除未完成草稿及音频；store 拒绝丢弃 ready 或已回执记录。每 5 分钟已保存的分段仍按原流程同步；存在已提交分段或当前为全天模式时不提供整次撤销，不能把当前段删除伪装成全部取消。

## 全天模式与时间标记

`Recording.mode` / `ClipEnvelope.mode` 区分 `quick` 和 `continuous`，旧数据缺字段时为 `quick`。两种模式共用一次启动的 AVAudioEngine 输入和五分钟文件保存链路，轮转文件时不停止麦克风。输入沿用实际硬件格式，当前接受 Float32 PCM，不强制假定 44.1 kHz；写入 AAC 文件的 processingFormat 必须匹配。

新 tap 提供可跨线程保留的 `AVReadOnlyAudioPCMBuffer`，回调只交给按帧数限制的串行队列（默认最多缓冲两秒），不在回调中写文件、保存索引或每包建立 Task。`AudioFrameSegmenter` 用 64 位帧计数切分跨界 buffer；每个有效帧恰好写入一次。writer 依序关闭旧文件、提交索引、开启新文件，期间采集继续。发生溢出、格式变化、已知输入帧不连续或写入失败时明确中断，保留已接收且可恢复的部分，不以完整记录报成功。

停止先停止输入，再排空有界队列、关闭并保存尾段；标记和取消也通过同一队列，避免与换文件竞争。成功取消不发保存通知；已经提交的段不能整体撤销。旧会话迟到的失败事件不能停止新会话。

`RecordingMarker` 包含稳定 ID、当前音频分段内的秒偏移 `offset`、`note` / `journal` 意图。`mark(intent:)` 从 writer 的有序帧位置取得偏移，store 写入成功才返回，UI 才显示“已标记”；不触发停止、切段或第二个采集器。标记数组随 envelope 同步，手机详情展示时间；`journal` 标记只是日记起点，尚未生成整理文本或 Obsidian 文件。旧数据缺少标记时按空数组解码。

## 后台录音与可观测性

Watch 和手机都配置 `UIBackgroundModes = [audio]`；`WKBackgroundModes` 不能代替这个音频字段。权限说明同时涵盖连续记录与主动口述。录音开始仍由用户在前台发起，不使用虚假的 workout session 保活。

显示时长来自输入队列实际接受的帧数；停止后以真正写入的帧数收尾，不用墙钟补足停滞。保存完成事件回主线程做列表刷新和同步，音频 writer 不等这些工作。AAC 有编码填充，录音有效时长按实际帧数及文件有效帧表验证，不能把忽略填充信息的解码器输出总长直接当额外录音。

一次录音开始前显式 `setActive(true)` 并启动 Engine，文件交接不反复激活音频会话。`RecordingProgressMonitor` 以单调时间检查真实输入帧数是否增长；执行中的观察超过 10 秒无进展时停止、保存并显示中断。回到前台也立即检查，但系统挂起期间无法保证按时检测，不把 `isRecording=true` 独立当作正在收音的证据。watchOS 的 Engine 自动关闭机制不能禁用，持续输入 tap 的实际后台运行与耗电必须在 S9 重新验证。

诊断默认关闭，仅显式 `SUIJI_DIAGNOSTICS_MINUTES=1...1440` 启用。60 秒采样、1600 条总上限、限时结束；结束诊断不停止用户录音。电池监测按启用前状态恢复。编码与原子写盘在串行后台队列处理，合并未写快照；进程突然结束可能损失最后诊断快照，不由此推定录音丢失。日志不含音频、转写或 Key，完整字段与测试方法见 [长录测试](LONG_RECORDING_TESTS.md)。

iPhone 主页把同日同来源、相邻间隔 −0.5 至 5 秒的连续录音折叠展示，仍保留每段稳定 ID、真实时长和详情入口；这是呈现分组，不新增逻辑 session 或抹去间隔。底部 Bot 只控制手机麦克风，不暗示远程控制 Watch。
