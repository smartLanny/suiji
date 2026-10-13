# 随记 · 原生 iPhone / Apple Watch

原生 SwiftUI iPhone / Apple Watch 客户端，第一阶段实现主动口述与分段持续录音 → 本地保存 → 手表同步手机 → 可替换的 OpenAI 兼容转写。Watch 轻点 Bot 开始连续录音，再点停止保存，长按可标记时刻，24 小时续航和后台稳定性仍需实测。原型里的提醒事项、Obsidian、健康、周/月回顾和 Agent 执行将在后续接入，当前原生 App 不显示模拟结果。

[GitHub 仓库](https://github.com/smartLanny/suiji) · [开发安装](docs/DEVELOPMENT.md) · [设计规范](docs/DESIGN.md) · [架构](docs/ARCHITECTURE.md) · [验收记录](docs/ACCEPTANCE.md) · [路线图](docs/ROADMAP.md) · [长录测试](docs/LONG_RECORDING_TESTS.md) · [睡眠与环境声音](docs/RECORDING_CONTEXT_RESEARCH.md) · [AI 硬件借鉴](docs/AI_WEARABLE_LESSONS.md)

## 开源许可

项目代码采用 [MIT License](LICENSE)。内置 Noto Serif SC 字体单独采用 [SIL Open Font License 1.1](Resources/Fonts/OFL.txt)，保留其原始版权和授权文件。角色与截图来源见 [素材说明](docs/ASSET_PROVENANCE.md)。

## 使用

1. 手机上打开「随记」，轻点底部 Bot，首次允许麦克风。再点 Bot 停止保存后记录直接进入时间线，没有第二次完成确认。
2. 在设置中填写基础地址、语音模型、API Key，点「保存并开始转写」。Key 仅存本机 Keychain，不发到手表。可连接不需要 Key 的私有服务。
3. 手表打开「随记」，轻点 Bot 开始连续录音，再点停止。长按拖动用于独立日记或录制中的重点标记；中央松手取消选择。手机不在附近也会先保存在手表；后台文件传输由系统排队。手机确认已持久保存后，手表才释放本地音频副本；手机上的原声遵循留存设置。
4. 点击时间线记录可回听、阅读、手动更正文字、分享文字，或选择一直保留这段原声。

自动转写首先保障前台使用，短时离开 App 会申请系统给予的完成时间。系统若暂停任务，下次打开继续；当前不承诺 App 退出后持续转写。失败记录保留原声，可在详情或设置重试。来电或系统音频中断会停止并保存，需要再次手动开始。

## 原声留存

- 默认自录音时间起 30 天，可设为 1–3650 天或永久保留。
- 仅成功写入非空转写、未手动保留、到期的手机原声可清理；录制中、转写中和转写失败的原声受保护。
- 清理在 App 恢复活动或转写完成时执行，不承诺到期秒级删除；缩短期限会先显示将清理的条数。
- 转写文字和记录索引继续保留。手表副本在手机确认保存后释放，与手机 30 天留存分开。
- 规则只管理本 App 的本地音频。第三方转写后端如何处理上传数据由该服务决定。

## 转写接口约定

`POST {baseURL}/audio/transcriptions`，multipart 字段为 `file`、`model`，以及非空时的 `language`。若填写完整 endpoint，不会重复追加路径；不会擅自追加 `/v1`。非空 Key 使用 Bearer 鉴权；响应需为 `{"text":"非空文字"}`。

使用 HTTPS；HTTP 仅限 loopback 本机调试。跨站及同站重定向均拒绝，避免把密钥发送到重定向地址。默认请求超时 120 秒，单片段不超过 25 MB；不要求后端支持流式、说话人识别或供应商专用参数。

录音为 AAC / m4a、单声道、44.1 kHz，每 5 分钟关闭并保存一个片段。录音器请求 64 kbps，但此次 iPhone 短片段实测约 132 kbps（6.59 秒 / 108,810 字节）；长录音容量与耗电必须另测。分段切换存在启动间隔，尚未验证全天连续录制的实际丢帧和功耗。S9 配置热修已观察到约半小时多段保存；具体解码和场景边界见验收记录。

## 工程

- `Sources/SuijiCore`：持久索引、去重、留存、通用转写客户端；同一组源码用于两个 App，Swift Package 用于 Mac 核心测试。
- `Shared`：录音、WatchConnectivity、状态管理和三种简洁主题。
- `iOS` / `Watch`：各自的 SwiftUI 原生页面和 App 生命周期。
- `scripts/generate_project.py`：无第三方依赖的 Xcode 工程生成器。首次生成后，也可直接打开 `Suiji.xcodeproj`。

部署目标 iOS 27 / watchOS 27。开发环境为 Xcode 27 beta 4。核心测试在 Mac 执行，App 分别用设备与模拟器 SDK 编译；具体运行验证见验收记录。

```sh
swift test --scratch-path /tmp/suiji-native-tests
xcodebuild -project Suiji.xcodeproj -scheme Suiji -destination 'generic/platform=iOS' -derivedDataPath /tmp/suiji-ios-build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Suiji.xcodeproj -scheme SuijiWatch -destination 'generic/platform=watchOS' -derivedDataPath /tmp/suiji-watch-build CODE_SIGNING_ALLOWED=NO build
```

使用 `/tmp` 构建可避免 iCloud 文稿目录附带 Finder 扩展属性影响签名。真实安装时在 Xcode 选择自己的 Personal Team 和设备，启用设备开发者模式并解锁。免费 Personal Team 的安装描述文件有效期为 7 天，过期后需要重新构建安装，不需要为本轮测试立即购买付费账号。[Apple 账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account)

## 验证范围

核心 33 项测试已通过，覆盖重启恢复转写队列、重复传输、损坏/不完整文件、回执前保护、30 天清理、永久与手动保留、转写错误、multipart 请求、日记/全天模式兼容、标记持久化与录音进展停滞检测。它们使用隔离临时文件及模拟 HTTP 响应，不代表真实语音识别准确率或 Watch 无线传输验收。

实际设备安装和测试结果见 [验收记录](docs/ACCEPTANCE.md)。仍需实测：手表与手机断联/重连、锁屏覆盖、来电中断、分段边界缺口、长时电量和真实后端转写。AirPods 路由及快捷启动入口尚未加入本轮验收。

参考：[Apple WatchConnectivity 文件传输](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:)) · [OpenAI 转写接口](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create)
