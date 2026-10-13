# 录音、睡眠运动与环境声音：证据和实现边界

核对日期：2026-10-13，Asia/Taipei。目标设备为 Apple Watch S9 + iPhone Air。本文区分官方 API 能力、项目实测和推荐策略；竞品官网说明不等于我们已实测。当前设备验收持续更新于 [ACCEPTANCE.md](ACCEPTANCE.md)，长测方法见 [LONG_RECORDING_TESTS.md](LONG_RECORDING_TESTS.md)。

## 1. watchOS 后台录音与分段

**已知 API 能力**

- `AVAudioSession.Category.record` 官方说明明确要求在 `UIBackgroundModes` 中加入 `audio`，以便 App 转入后台、例如屏幕锁定时继续录音；需要麦克风授权。该类别同时会抑制大部分系统播放声音，但不能阻止电话、警报或其他非混音音频会话中断录音。[Apple：record](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record)
- Apple 的 Info.plist 文档明确说明 watchOS 4 起所有 App 均可后台录音，录音需在前台开始。这里的能力依据是录音与 `UIBackgroundModes=audio`，不需要伪播放或为了保活创建运动会话；播放专用的 `longFormAudio` 路由要求不能直接套用到录音。[Apple：UIBackgroundModes](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/iPhoneOSKeys.html#//apple_ref/doc/plist/info/UIBackgroundModes)
- `AVAudioRecorder.record(forDuration:)` 在 watchOS 4 起可用，到指定时长会停止。`audioRecorderDidFinishRecording` 可通知正常完成，但其文档明确不用于音频中断通知；中断应观察音频会话事件。两个 API 不承诺后台下一段启动时延或音频无缝连续。[Apple：定时录音](https://developer.apple.com/documentation/avfaudio/avaudiorecorder/record(forduration:))、[完成代理](https://developer.apple.com/documentation/avfaudio/avaudiorecorderdelegate/audiorecorderdidfinishrecording(_:successfully:))

**当前项目与实测边界**

2026-10-13 旧实现使用 `.record`、5 分钟 `record(forDuration:)` 和代理轮转；随后固定声源实测确认一处约 1.6 秒缺口。2026-10-14 已改为 AVAudioEngine 持续采集、只按帧轮转文件；离线写盘通过，S9 新路径仍需单独验收。当前实现见 [架构](ARCHITECTURE.md)，历史与新测试分列于 [验收记录](ACCEPTANCE.md)。

主线程在 2026-10-13 取得配置热修版的阶段性证据：一轮录音最终产生 6 个 300 秒完整段和约 30.28 秒尾段，7 段均为 ready；首文件 ffprobe 时长 300.001814 秒且完整解码通过。相邻 `recordedAt` 减去上段时长存在候选边界间隔，**不是精确音频缺失量**。这证明已观察到多次轮转，不代表 24 小时覆盖、睡眠/运动共存或续航验收通过；详细后续结果以验收文档为准。

当前计时和标记以录音器音频时间为准，封口时再结合文件可读时长，不用墙钟等待时间补录音时长。若系统暂停了录音，不能仅因时间流逝把这段空白声称为已覆盖。

## 2. 睡眠、专注与运动

| 场景 | 官方可确认 | 尚不能确认 |
| --- | --- | --- |
| Sleep Focus | 管理通知、睡眠显示等；可以按计划或手动开启 | 不等同于已入睡或设备锁定；未找到“开启即禁止第三方后台录音”的统一规定 |
| 睡眠追踪 | Watch 可生成睡眠记录，HealthKit 提供带开始/结束时间的阶段样本 | 没有保证实时入睡/醒来回调或固定交付时延；不能因尚无样本判定清醒 |
| Focus API | 授权后 `INFocusStatus.isFocused` 提供可为空的专注状态 | 没有具体 Focus 名称/类型；不能直接识别 Sleep Focus |
| 自己创建的运动 | `HKWorkoutSession` 可提供状态；Watch 一次运行一个运动会话 | 该单会话限制不是普通 `.record` 必须停录的依据 |
| 其他 App 的运动 | 授权后可读取已保存的 HealthKit 运动记录 | 未证实可通用地实时读取其他 App 当前运动状态；恢复自己运动的 API 不是全局查询 API |
| 自动运动识别 | Apple 可提醒用户开始记录，并补记已完成的活动部分 | 提醒不等于第三方 App 收到可靠实时“正在运动”开关 |

来源：[Apple：睡眠追踪和 Sleep Focus](https://support.apple.com/guide/watch/track-your-sleep-crpxel1lvun9/watchos)、[SleepAnalysis 阶段样本](https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis)、[INFocusStatus](https://developer.apple.com/documentation/intents/infocusstatus)、[HKWorkoutSession](https://developer.apple.com/documentation/healthkit/hkworkoutsession)、[恢复自己的运动](https://developer.apple.com/documentation/healthkit/hkhealthstore/recoveractiveworkoutsession(completion:))、[Apple 运动提醒](https://support.apple.com/guide/watch/stay-active-with-apple-watch-apd9c3cfe913/watchos)。

没有找到 Apple 官方对“第三方 `.record` + 系统睡眠追踪/运动追踪”的全面并行保证或全面禁令。睡眠专注、睡眠追踪、Apple Workout、自动运动提醒以及运动语音反馈需分别验收，不能把其中一种结果推广到所有组合。

## 3. 电话、Siri 与导航音频

竞争的非混音音频会话和系统警报可以使音频会话失效；AVFoundation 会在中断时暂停录制。用户接受电话可能导致 App 挂起。Apple 的 Siri 示例说明它可以中断音频，但没有承诺每次 Siri 调用对每种 Watch 录音路由都表现相同。[Apple：中断处理](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)、[音频会话中断指南](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html)

导航和运动播报可采用混音、压低其他音频等策略，因此不能把“有播报”一律判定为录音中断，也不能保证不中断。`duckOthers` 等选项只适用于指定的播放类别，不能直接加入当前 `.record` 配置。[Apple：duckOthers](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/duckothers)

当前实现观察系统音频会话停用事件，保存已录部分并显示停止原因；没有承诺自动恢复。验收应记录实际会话事件、可解码片段及覆盖缺口，而不是只检查 UI 计时还在走。

## 4. Auday 的 Mark 与自动重点

Auday 官网演示的触屏交互为轻点开始、录制中轻点标记、长按 1 秒停止、上下滑动切页；这里只核对官网演示，未安装或实测其 App。[Auday 官网](https://auday.ai/)

FAQ 明确：Mark 保存点击时刻，让 AI 更关注附近的对话；它不选择某一句话，也不保证产生 Highlight。**AI 不依赖 Mark 也能发现 Highlights**。标记应是可选书签，不能让用户为了获得全天重点而不断点击，也不应把标记等同于任务指令。[Auday FAQ：What does a Mark do to Highlights?](https://auday.ai/faq)

FAQ 同时说明全天/24 小时是目标用途，电量、存储与系统中断会限制覆盖；官网团队续航测试属于特定 Series 11 的单次观察，不能转作 S9 实测结论。[Auday FAQ：全天录音与续航](https://auday.ai/faq)

**本产品建议**：延续当前容易理解的轻点持续录音/再点暂停，标记作为次要快捷动作。自动重点发现使用转写、时间范围和可用上下文；人工 Mark 只提升附近内容的处理优先级，不作为处理前提。自动重点处理尚未完成原生接入。

## 5. 环境声音识别

**已知能力与类别边界**

- Apple SoundAnalysis 可本地分析音频文件或流，内置分类器覆盖 300 多种声音。`SNClassifySoundRequest` 从 watchOS 6 可用，内置分类器初始化方法从 watchOS 8 可用；类别与支持窗口应分别读取 `knownClassifications`、`windowDurationConstraint`。官方介绍含车辆等类别，但本次未在官方静态列表确认电脑打字/交通的准确 identifier，不能把乐器键盘当作电脑键盘。[Apple：分类请求](https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest)、[内置分类器初始化](https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest/init(classifieridentifier:))
- Apple 明确指出窗口和阈值会影响误检/漏检，相近声音甚至人也难以只靠音频区分；分数不能被包装成已验证的准确率。[Apple WWDC21：SoundAnalysis](https://developer.apple.com/videos/play/wwdc2021/10036/)
- YAMNet 是 521 类音频事件模型，输入为 16 kHz 音频，使用 0.96 秒窗口、0.48 秒步长；官方类别表明确含 `Typing`、`Computer keyboard` 和 `Traffic noise, roadway noise`。有类别不等于 S9 录音中已经达到可靠识别率。[TensorFlow：YAMNet](https://blog.tensorflow.org/2021/03/transfer-learning-for-audio-data-with-yamnet.html)、[TensorFlow 官方类别表](https://github.com/tensorflow/models/blob/master/research/audioset/yamnet/yamnet_class_map.csv)
- PANNs 提供片段级标签和逐帧事件输出；CLAP 可用音频/文本相似度进行可替换的分类或检索。二者作者仓库证明功能，不证明移动端耗电、耗时或全天场景准确率；CLAP 相似度不应直接当作已校准概率。[PANNs 作者接口](https://github.com/qiuqiangkong/panns_inference)、[LAION CLAP](https://github.com/LAION-AI/CLAP)

**推荐但未实现的最小方案**

1. 优先在 iPhone 对已接收音频离线处理，Watch 负责稳定采集。SoundAnalysis 支持 watchOS，但首选手机是减少手表负担的工程选择，不是 API 限制；手机后台计算时机也不能承诺。
2. 可先试每分钟选取约 10 秒音频窗口；这是采样参数建议，需测短事件漏检和耗电。保存分段 ID、窗口起止时间、类别、模型分数、模型版本与 `unknown`。采样未覆盖的区间不得自动填满成持续事件。
3. 合并相邻且有连续证据的窗口，保留不确定性。界面呈现“疑似键盘声/交通声”；键盘声不能证明本人在工作，交通声不能确定精确地点。地点与活动只能作为独立来源的上下文，推断必须标明。
4. 环境识别采用独立可选 `AudioEventClassifier` 能力接口。当前 OpenAI 兼容 `/audio/transcriptions` 最小契约仅要求非空 `text`，不保证环境音标签；ASR 中的噪声词或括号不能当作可靠声音检测。支持扩展标签的服务须声明能力与返回结构。[OpenAI：Transcriptions](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create)

## 6. 默认策略与待验收项

以下为建议，**尚未实现自动睡眠/运动策略**：

- 睡眠健康记录与原音独立。初版采用可执行的“睡前手动暂停，次日手动开始”；用户明确选择保留夜间原声时继续录音。不依据粗粒度 Focus 状态或迟到的睡眠样本偷偷停录/重启。
- 后续如加入固定夜间截止时间，应持久保存用户选择的时段，并在正在运行的录音流程中执行停止。暂停后自动后台启动录音不能从现有 API 文档保证，需单独设计与验收。
- 运动默认不一概暂停；若系统真实中断，保留已录部分、明确覆盖缺口和恢复状态。历史运动/睡眠样本可在稍后到达后按其原始时间范围补充回顾，不伪装成实时传感器。
- 夜间是否录音与原音留存是两项设置。已有普通音频遵循本项目留存策略；文字与记忆独立长期保存，原声删除后不能显示可回放。留存天数由产品配置决定，不由 Apple API 决定。

仍需 S9 佩戴真机验收：长时息屏与后台轮转；开启 Sleep Focus 并实际睡眠追踪；Apple Workout 与运动提醒/语音反馈；电话、Siri、导航及路由切换；断连后恢复与回执；不充电、尽量无调试干扰的电量测试。上述 API 支持及目前几段有效音频都不能代替这些验收。
