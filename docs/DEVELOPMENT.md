# 开发与安装

工作目录为仓库根目录（本次会话中的 `outputs/suiji-native`）。当前验证环境：Xcode 27 beta 4、iPhone Air / iOS 27.0.1。生成的 App 最低系统为 iOS 27 / watchOS 27；SwiftPM 核心声明的最低平台为 macOS 14 / iOS 17 / watchOS 10，这不代表 App 已兼容这些旧系统。

## 工程生成

```sh
python3 scripts/generate_project.py --team '<YOUR_TEAM_ID>'
open Suiji.xcodeproj
```

生成器扫描 `Sources/SuijiCore`、`Shared`、`iOS`、`Watch` 各目录直接下的 `.swift`，重写 project、共享 schemes 和 Info.plist，并将 Watch App 嵌入手机 App。新增嵌套目录或能力时要同步修改生成器。需要长期保留的工程设置应写入生成器，不只手改生成结果。

**每次重新生成签名工程都传相同 `--team`。** 省略参数会清空两端的 DEVELOPMENT_TEAM。不要把个人 Team ID、证书、UDID、邮箱或 API Key 写进共享文档；本地值自行替换。无签名编译可省略 Team。

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
4. 在配对 Watch 安装并运行 `SuijiWatch`，验证录音、断连排队、手机保存及回执。Watch App 已嵌入手机产物，尚未证明配对设备安装与传输成功。

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

私有仓库为 [smartLanny/suiji](https://github.com/smartLanny/suiji)。只提交源码、资源、生成脚本及可维护文档，不提交设备容器、录音、manifest、凭据或签名材料。提交前记录相关测试与真机证据；在 [验收表](ACCEPTANCE.md) 更新结果，保持「已实现」「已编译」「已真机验证」分别可查。

GitHub Actions 在 push / pull request 后运行纯核心 SwiftPM 测试；iOS 27 / watchOS 27 App 的编译和界面验收仍在具备相应 SDK 的本机执行。

持久化变更需考虑现有 manifest 版本及旧数据迁移。公共行为与数据路径见 [架构](ARCHITECTURE.md)，后续范围见 [路线图](ROADMAP.md)。
