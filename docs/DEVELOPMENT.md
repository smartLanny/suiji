# 开发与安装

工作目录为仓库根目录（本次会话中的 `outputs/suiji-native`）。当前验证环境：Xcode 27 beta 4、iPhone Air / iOS 27.0.1。生成的 App 最低系统为 iOS 27 / watchOS 27；SwiftPM 核心声明的最低平台为 macOS 14 / iOS 17 / watchOS 10，这不代表 App 已兼容这些旧系统。

## 工程生成

```sh
python3 scripts/generate_project.py --team '<YOUR_TEAM_ID>'
open Suiji.xcodeproj
```

生成器扫描 `Sources/SuijiCore`、`Shared`、`iOS`、`Watch` 各目录直接下的 `.swift`，重写 project、共享 schemes 和 Info.plist，并将 Watch App 嵌入手机 App。新增嵌套目录或能力时要同步修改生成器。需要长期保留的工程设置应写入生成器，不只手改生成结果。

公开仓库的 DEVELOPMENT_TEAM 留空。可以本地用 `--team` 生成签名设置，但不要提交个人 Team 的工程差异；临时构建也可给 `xcodebuild` 传 `DEVELOPMENT_TEAM=<YOUR_TEAM_ID>`，同时作用于手机和 Watch。不要把证书、UDID、个人邮箱或 API Key 写进共享文档。

## 验证命令

```sh
swift test --scratch-path /tmp/suiji-native-tests
```

```sh
xcodebuild -project Suiji.xcodeproj -scheme Suiji \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/suiji-ios-build CODE_SIGNING_ALLOWED=NO build
```

```sh
xcodebuild -project Suiji.xcodeproj -scheme SuijiWatch \
  -destination 'generic/platform=watchOS' \
  -derivedDataPath /tmp/suiji-watch-build CODE_SIGNING_ALLOWED=NO build
```

构建缓存使用 `/tmp`：此前 Documents 下的 Finder / resource fork 扩展属性导致 CodeSign 失败，使用独立 scratch / DerivedData 路径可避开该已知环境问题。核心测试通过并不等于设备权限、后台运行或真实服务通过。检查项目源文件/配置变化后再做与改动相称的验证。

## 真机运行

1. 在 Xcode 登录自己的 Apple Developer 账号；生成工程时传入自己的 Team，检查两个 target 的自动签名。连接并选择 iPhone，按系统提示开启开发者模式和信任，运行 `Suiji`。
2. 允许麦克风，点「说一句」，点「停止并保存」后直接返回并保存，无第二个完成确认。进入记录回听；不要把启动成功当作音频保存成功。
3. 手机设置填写服务地址和模型，按服务要求输入 Key；无需 Key 的网关可留空。真实上传应由用户主动配置服务，测试不使用个人 Key。Key 仅进手机 Keychain。
4. iPhone 的 Watch App →「我的手表」→ 向下找到「可用 App」→「随记」→「安装」（新版系统可能归于 App 分组）。保持手表与手机已配对、联网且靠近。最新版手机产物已嵌入 Watch App；本工程要求 watchOS 27。见 [Apple 安装说明](https://support.apple.com/en-us/109023)。
5. 如果列表中没有随记或安装失败，在 Xcode Device Hub 中确认配对手表已可用；选择 `SuijiWatch` scheme 和该实体 Watch，再运行。需要先处理 Apple 提示的手表开发者模式、设备注册及签名；不要用仅手机安装成功推断 Watch 已安装。见 [Xcode 配对说明](https://developer.apple.com/documentation/xcode/pairing-your-devices-with-your-mac)。
6. 首次安装或更新后先打开手机端随记一次，让手机准备接收；Watch 安装后验证录音、断连排队、手机保存及回执。2026-10-13 已在 S9 / watchOS 27.0 验证首次短录、唯一导入与手机回执；后台多轮稳定性与离线重传仍待验收。

### Watch 安装转圈后回到“安装”

不要仅凭该界面猜测原因。2026-10-13 先后捕获了两种不同失败：

- `0xe8008015`：描述文件不包含目标 Watch。先在手表开启开发者模式，完成对 Mac 的配对/信任；Xcode 发现实体 Watch 后，用 `SuijiWatch` scheme 选择它构建，允许自动注册设备及更新签名。
- `0xe8008017`：签名资源已被修改。此次增量构建替换了 `embedded.mobileprovision`，却保留旧 Watch 签名。全新 DerivedData 构建消除了本地校验错误，无需修改 App 代码或卸载手机数据。

更新描述文件后，清理构建或使用全新构建目录，验证 Watch 本体、手机中的 Watch 副本及手机包：

```sh
xcodebuild -project Suiji.xcodeproj -scheme Suiji \
  -destination 'id=<YOUR_IPHONE_UDID>' \
  -derivedDataPath /tmp/suiji-paired-build \
  DEVELOPMENT_TEAM='<YOUR_TEAM_ID>' \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration clean build

codesign --verify --deep --strict /tmp/suiji-paired-build/Build/Products/Debug-watchos/SuijiWatch.app
codesign --verify --deep --strict /tmp/suiji-paired-build/Build/Products/Debug-iphoneos/Suiji.app/Watch/SuijiWatch.app
codesign --verify --deep --strict /tmp/suiji-paired-build/Build/Products/Debug-iphoneos/Suiji.app
```

本次手机 Watch App 的安装入口重试仍未成功，开发工具直接安装同一个干净构建的内嵌 Watch 包成功，随后启动和实际屏幕确认通过。开发期可用 Xcode 的 Watch scheme 运行，或 `xcrun devicectl device install app --device <YOUR_WATCH_UDID> <WATCH_APP_PATH>` 安装。不要将这个结果记为手机端安装入口已修复；后续版本仍需复测该入口。

Personal Team 属于个人设备测试方式，免费签名配置有效期为 7 天，过期需重新构建安装；见 [Apple 账号能力说明](https://developer.apple.com/help/account/basics/about-your-developer-account)。当前流程不等于 TestFlight / App Store 发布。

## 持续开发约定

### 模拟器与接口联调

用 Xcode 安装 iOS 27 Simulator runtime，创建 iPhone Air，再用 `Suiji` scheme 选择该模拟器运行。本机 Xcode 27 beta 4 通过 Device Hub 显示虚拟设备。模拟器可检查界面、保存及 HTTP 链路，不能替代 WatchConnectivity 配对真机测试或续航测量。

安装到模拟器时保留普通签名，不加 `CODE_SIGNING_ALLOWED=NO`；该选项只用于编译检查。iOS target 使用 `Config/Suiji.entitlements` 配置本 App 的 Keychain 标识，生成器通过签名前缀展开，不与其他 App 共享。模拟器实际使用 Xcode 产出的 `Suiji.app-Simulated.xcent`，不能仅凭 `codesign -d` 输出为空判断未配置。缺少该权限会造成 Keychain `-34018`。

```sh
xcodebuild -project Suiji.xcodeproj -scheme Suiji \
  -destination 'platform=iOS Simulator,name=<YOUR_SIMULATOR_NAME>' \
  -derivedDataPath /tmp/suiji-simulator-build build
```

测试通用接口时可在 Mac 运行 `python3 scripts/mock_transcription_server.py`，在模拟器填 `http://127.0.0.1:8766/v1`，模型填 `simulator-contract-test`，Key 留空。服务只监听 loopback，15 分钟后自动结束；也可随时 Ctrl+C。`--scenario empty`、`unauthorized`、`rate-limited` 分别返回空结果、401、429，便于验证原声保留与重试。

该服务不识别语音，结果明确标记“模拟接口测试”。与真实 ASR 的质量和费用验收分开。模拟器测试数据及真实手机测试录音均不入库。

### 提交与自动检查

仓库为 [smartLanny/suiji](https://github.com/smartLanny/suiji)。只提交源码、资源、生成脚本及可维护文档，不提交设备容器、录音、manifest、凭据或签名材料。提交前记录相关测试与真机证据；在 [验收表](ACCEPTANCE.md) 更新结果，保持「已实现」「已编译」「已真机验证」分别可查。

GitHub Actions 在 push / pull request 后运行纯核心 SwiftPM 测试；iOS 27 / watchOS 27 App 的编译和界面验收仍在具备相应 SDK 的本机执行。

持久化变更需考虑现有 manifest 版本及旧数据迁移。公共行为与数据路径见 [架构](ARCHITECTURE.md)，后续范围见 [路线图](ROADMAP.md)。
