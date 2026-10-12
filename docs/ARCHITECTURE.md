# 原生架构

本文描述 2026-10-12 的实际实现。当前闭环是录音、本地保存、Watch 向手机同步、通用 ASR 转写、回听和原声留存；完整产品范围见 [路线图](ROADMAP.md)。

## 模块与数据路径

| 模块 | 责任 |
| --- | --- |
| `Sources/SuijiCore` | 录音模型、文件与 manifest 持久化、留存规则、通用 ASR 客户端；通过 SwiftPM 测试 |
| `Shared/AudioCapture.swift` | AVAudioRecorder、麦克风权限、5 分钟分段、中断保存、启动时恢复未完成录音 |
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
- 同步状态独立于转写。`transferFile` 排队或系统传输完成不等于手机已保存。手机完成导入与 manifest 保存后才发 `recordingReceipt`；Watch 收到回执并写入 `phoneReceivedAt` 后才释放副本。系统决定传输时机，未承诺到达时延；配对实机闭环尚未验收。
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
