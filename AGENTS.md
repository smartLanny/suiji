# 随记开发约定

- 以 `docs/ROADMAP.md` 区分完整产品方向与当前原生实现；更新验收结果时写入 `docs/ACCEPTANCE.md`，注明测试设备或模拟器。
- UI 改动先读 `docs/DESIGN.md`。已确认的原型是视觉基线；使用原始三主题角色和暖纸配色，保持操作少、录完自动返回。新增设计方向需用户明确提出。
- 真实 App 只显示真实记录及其状态。演示数据仅用于明确标识的模拟器测试。
- 保持本地保存优先、稳定 ID 去重、手机持久回执后才释放手表副本、未完成转写不自动清理。API Key 存 Keychain。
- 修改核心逻辑运行 `swift test --scratch-path /tmp/suiji-native-tests`；改双端代码编译 iOS 与 Watch；UI 改动在模拟器或真机查看实际渲染和主要交互。源码生成工程用 `scripts/generate_project.py`，新增文件后重生成。
- 发布到仓库前排除录音、个人转写、API Key、签名文件、构建目录和设备标识。设备和后端密钥均留在本机。
- 范围保持简单，避免顺手添加未要求的集成。提醒事项、Obsidian、健康与 Agent 按路线图分阶段接入。
