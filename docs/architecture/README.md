# 当前工程边界

Mac 采用 SwiftPM，iOS 采用 Xcode 工程。依赖提交由 Package.swift / Package.resolved 锁定，Mac 只链接 WhisperKit 产品。工具链、构建与产物统一见 [开发工作流](../development.md)。

iOS 只链接同一份 Core 源码，复用 Task 状态显示文本，不链接推理 SDK。Sources/VoxlineIOS 提供只读任务／字幕浏览；手动导入 .voxline / JSON 后验证、迁移并保存到本地 Documents。同任务 ID 再次导入替换本地只读副本，原文件不写回，Mac 书签不传入 iOS。媒体关联、播放及编辑由 VXL-030 交付。

## 模块职责

- VoxlineCore：ProcessingTask、参数快照、有序媒体条目、字幕版本、媒体身份、JSON 编解码、验证及转写协议。只依赖 Foundation，不保存设备路径、书签或密钥。
- VoxlineWhisperKit：固定版本模型清单、下载与安装校验、本地目录占用和 WhisperKit 实例生命周期。SDK 类型只存在于该模块；应用接收文件下载进度、安装和加载状态。Provider 与恢复由后续条目接入，同一进程复用已加载实例。
- VoxlineMedia：AVFoundation 原生能力检查、流式 SHA-256 和设备本地只读书签。AVFoundation 类型不进入 Core 或 Task 文件；媒体保持引用，书签与媒体条目 ID、内容及音轨绑定。
- VoxlineApp：单窗口导航、TaskLibrary、任务准备、详情、原生播放、字幕校对及模型／服务管理界面。绑定修改 Task，TaskLibrary 通过 TaskDocumentCodec 原子保存唯一任务文件。UI 不导入 WhisperKit。

Core 和字幕文档不依赖 UI、AVFoundation 或具体推理 SDK。JSON 是持久字幕权威来源，SRT 是导出物，内存任务库是界面状态。

## Task 持久化

新任务保存至应用本地 Application Support/Voxline/Tasks；导入已有文件后保存到原 URL，不保留额外副本。TaskLibrary 登记不写文件，保存先编码验证，再原子写入，成功后更新任务库。读写或目录错误明确显示，损坏任务保留错误条目，保存失败保留编辑状态与最后成功写入的成果。

版本 2 的 .voxline 根对象为 ProcessingTask，版本 1 的 SubtitleProject 仅作为验证和迁移输入。旧媒体条目沿用原项目 ID，从而复用书签；已有字幕标记为待确认，不虚构处理完成。打开不主动改写原文件，运行条目转换为 interrupted 并保留成果，实际恢复由 VXL-012/026 实现。

Task 保存一份参数，有序媒体条目分别保存来源、身份、字幕与状态。整体状态和统计从条目计算。参数冻结要求至少一个可处理媒体，已失败或取消的输入不阻塞其余合法条目。冻结只固定参数，不调用 Provider 或生成成果。

格式、ID、时间、媒体边界、译文来源和失败原因都在编码前与读取后验证。损坏、未来版本或非法数据抛出错误，不创建空 Task 替代原文件。

长期决定见 [ADR-0005](../ADR/0005-task-document-format.md) 与 [ADR-0006](../ADR/0006-single-window-task-library.md)。

## 输入与文件访问

TaskConfigurationView 以具体 Task 对象驱动 sheet，在独立草稿上多选 MP4/MOV/M4V、M4A/MP3/WAV，逐项展示能力、失败原因和音轨。多语言音轨必须选择；单音轨可直接选定。错误输入与合法条目共同提交，书签确认失败的新增条目标记失败并保持未关联，便于修复。已有媒体字幕保持原值。

MediaInspector.shared 在进程内复用相同 URL、文件大小与修改时间的检查结果，每次仍打开文件验证实际权限。文件元信息变化后重新计算哈希；确认和重新关联校验内容与所选音轨。新进程首次访问重新检查，不把设备媒体索引写入 Task。缓存不检测大小和修改时间同时保持不变的内容改写。

LocalMediaStore 保持只读沙盒书签，缺失、损坏、授权失败和内容不符均明确处理。播放前验证身份，过期书签经验证后更新；播放期间持有访问，关闭详情释放访问与观察器。原生预览只加入用户选择的音轨，保留源轨道时间和视频变换。

任务准备等待期间保护原 Task 快照，实际发生修改时拒绝覆盖。取消停止未提交工作。文件访问和恢复只处理实际需求，不加入账户角色、执行租约或云冲突框架。

## 执行与界面

MainWindowView 组织任务列表、准备表单、任务详情和媒体详情。NativeControlSurface 在系统 26 及以上使用原生 Liquid Glass，旧系统使用 Material；原生组件优先。系统 26 视觉和辅助功能设置的完整运行验收仍由 VXL-047 跟踪。

真实抽音频、转写、API 翻译和持久队列尚未接通。未接通的开始、重试及重译明确不可用；禁止计时模拟进度、示例字幕或伪译文。模型安装清单匹配且文件完整时显示已安装；只有当前进程中的 WhisperKit 完成加载才显示已加载。模型规则见 [ADR-0007](../ADR/0007-pinned-local-model-installation.md)。

原始 ASR 证据和可读字幕分开：RawTranscriptionSegment 保留原始对齐，转换为 SubtitleCue 前验证。切分及 Provider 不能排序、裁剪或丢弃文本来伪装成功。过期译文保留旧来源并显示待重译，新的自动处理不能覆盖较新的手工编辑。

应用打包启用 App Sandbox、用户选择文件读写、应用范围书签和网络客户端。iCloud 同步暂废弃；YouTube 来源后续实施；产品只支持 macOS 与 iOS。

## 模型安装与加载

BaselineModel.json 是固定仓库提交、必需文件和摘要的权威清单，打包时复制到应用 Resources。缺少清单明确失败，不读取开发目录替代。

每个型号的 Application Support/Voxline/Models 目录包含 SDK 缓存、权重、分词器和 installation.json。全部文件的长度与仓库对象摘要通过后才写入安装记录；LFS 使用 SHA-256，普通文件使用 Git blob SHA-1。目录刷新检查记录、版本和文件长度，实际加载前再次校验摘要。

WhisperModelStore 持有一个已加载 SDK 实例。分词器从固定本地目录预解析，实际 SDK 加载完成才显示已加载；进程重启后只识别安装状态。加载实例不可删除或重新下载，卸载释放引用。未知型号明确拒绝，Task 参数页保留旧值。

下载进度是 SDK 的文件完成比例，区分权重、分词器和校验。取消等待实际操作结束，操作标识隔离迟到回调。重新下载清理对应目录后完整下载；部分文件与缓存计入占用并可清理。空间查询、网络、读写和校验错误显示实际原因。决定理由见 [ADR-0007](../ADR/0007-pinned-local-model-installation.md)。
