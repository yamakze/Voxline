# 开发工作流

工具链：Xcode 26.2 / Swift 6.2；Mac 基线 macOS 15，iOS 基线 iOS 18。所有命令从仓库根目录执行。

## Mac

```sh
Scripts/build-app.sh debug
Scripts/compile_and_run.sh debug
swift test
```

compile_and_run.sh 构建成功后停止当前仓库产物对应的旧进程，启动 build/Voxline.app。

## iOS

Voxline.xcodeproj 保留 VoxlineIOS scheme，应用 target 为 VoxlineApp；两平台应用源码统一在 Sources/Voxline/App。能力框架直接使用相同源码目录，WhisperKit 产品固定到与 SwiftPM 相同的提交。模型清单作为框架资源打包，权重由模型页按需下载。Xcode 可打开工程进行断点调试与 SwiftUI Preview。

```sh
Scripts/build-ios-ipa.sh
Scripts/build-ios-ipa.sh debug
Scripts/compile_and_run_ios.sh
Scripts/compile_and_run_ios.sh --list
Scripts/compile_and_run_ios.sh <模拟器UDID> release
```

- build-ios-ipa.sh 默认为 release，构建 iPhoneOS 设备包，关闭代码签名，创建全新的 Payload 后替换 build/ios/Voxline-unsigned.ipa。失败不会覆盖上一次 IPA；打包不携带 macOS 扩展属性。
- compile_and_run_ios.sh 默认为 debug，优先选择已启动的 iOS 模拟器，否则选择第一个可用 iPhone。指定 UDID 可切换设备；没有可用 runtime 或参数不合法时明确退出。
- 模拟器使用本地临时签名，使 Keychain 可实际读写；不需要开发证书。设备 IPA 保持未签名，自行签名时应用和嵌入框架均须有效签名。
- 构建成功后按需启动模拟器、等待开机、安装应用并替换旧进程；保留应用数据。构建失败时不安装、不终止旧应用。
- build-ios.sh 是两者共用的构建入口，分别保留 build/ios/device 和 build/ios/simulator 下的 DerivedData。完整日志为对应目录下的 build.log，包含总耗时和 Build Timing Summary。
- IPA 是设备架构 arm64，不能安装到模拟器。普通真机需有效签名；可用现有签名工具处理 IPA，或在 Xcode 的 Signing & Capabilities 中选择开发 Team 后运行。

当前 iOS 功能与文件规则见 [架构](architecture/README.md)。

原生集成测试复用实际 iOS 模块和 Apple 结果映射测试，检查模型清单资源、真实 Keychain、独立文件副本及错误边界：

```sh
xcodebuild -project Voxline.xcodeproj -scheme VoxlineIOS \
  -destination 'platform=iOS Simulator,id=<模拟器UDID>' \
  -derivedDataPath build/ios/simulator/DerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

测试只使用随机服务名下的临时 Keychain 项，完成后删除。Apple Translation 不支持模拟器；本机语言准备、翻译质量及模型真机资源预算通过设备验收。

## 软件包验证

测试与能力模块归属一致：Core 的格式、字幕与 SRT，Media 的访问、提取、播放与烧录，Translation 的协议与凭据，WhisperKit 的模型与 Provider，Workflow 的持久化与队列。VoxlineAppTests 检查 Apple 语言标识匹配与响应 ID 映射；iOS 原生集成测试检查资源、Keychain、设备副本和错误边界。平台 source guard 的检查通过实际 Mac 与 iPhoneOS／模拟器构建完成；SwiftUI 页面、文件选择器和系统翻译会话仍须目标平台运行验收。

## 缩短反馈时间

1. 日常使用 debug 和固定 DerivedData，保留 .build 与模型缓存；只在需要发布包、性能测量或检查 Release 行为时使用 release。不要把 clean 作为日常构建步骤。
2. UI 调整先用 Xcode Canvas / SwiftUI Preview，再跑目标平台。能力模块与固定软件包依赖保持增量缓存；设置页调整不需要重复下载模型或重跑推理。
3. 修改哪个模块，就先执行对应验证。例如 Core 参数修改使用 swift test --filter ProcessingTaskTests；UI 布局使用构建和目标页面验收。阶段提交前按影响范围做回归，避免每个排版修改都重复全量验证。
4. 复用固定小媒体和 Task 夹具检查选择、失败、导入与导航；转写验证独立执行。不要为了观察 UI 重复下载模型或完整转写视频。测试数据不得把模拟处理伪装成真实成果。
5. 从 build.log 的 Timing Summary 定位慢步骤，再调整模块依赖或复杂 SwiftUI 表达式。任务耗时是步骤累加，可能并行，不能当成总耗时。

Apple 说明后续构建可复用增量结果，并提供命令行耗时汇总：[增量构建](https://developer.apple.com/documentation/xcode/improving-the-speed-of-incremental-builds)、[Xcode 并行构建](https://developer.apple.com/videos/play/wwdc2022/110364/)。真机签名与安装见 [运行到设备](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html)。

验收结果统一记录于 [GitHub Project](https://github.com/users/yamakze/projects/1)。

## 私有样本提取验证

```sh
VOXLINE_AUDIO_SAMPLE="/absolute/path/sample.mp4" swift test --filter realSampleExtraction
```

使用现有样本的首个音轨验证提取，产物位于忽略目录 tmp/audio-validation；产品处理始终使用任务明确选择的音轨。小视频测试使用仓库中的自生成夹具，不依赖视频编码器。

## S001 Provider 验证

```sh
VOXLINE_MODEL_DIRECTORY="/absolute/path/Models" \
VOXLINE_PCM_DIRECTORY="/absolute/path/S001-chunks" \
swift test --filter 'realSampleProvider|realProviderLanguageAndCancellation'
```

模型目录是已完整安装的基准型号父目录；PCM 目录是 S001 提取出的九块缓存。验证使用真实 SDK 和本地模型，保留每个成功／对齐失败块的证据，再检查自动语言识别、解码取消、模型占用和卸载；不下载模型，不将对齐失败算作转写成功。产物位于忽略目录 tmp/provider-validation；默认 swift test 跳过此私有样本入口。

## 已保存转写证据的字幕切分验证

```sh
VOXLINE_TRANSCRIPTION_EVIDENCE_DIRECTORY="/absolute/path/selected-evidence" \
swift test --filter SubtitleSegmentation
```

目录包含选定的 Provider 原始 JSON，至少各有一份成功和失败／取消记录。验证成功记录的原文完整性、源时间、唯一 ID 和保存读取；明确拒绝不完整转写。切分产物位于忽略目录 tmp/segmentation-validation，保留源文件名便于对应。此验证复用证据，不重新运行模型，也不代替听录或整段视频质量验收。默认测试跳过该私有样本入口。

## 检查点与已保存 S001 证据验证

```sh
VOXLINE_TRANSCRIPTION_EVIDENCE_DIRECTORY="/absolute/path/selected-S001-evidence" \
VOXLINE_AUDIO_CACHE_MANIFEST="/absolute/path/S001-chunks/audio.json" \
swift test --filter 'ProcessingCheckpoint|TaskLibraryTests'
```

选择与提取清单逐块匹配的一份 S001 原始证据，包含成功与失败范围；30 秒片段不会匹配完整清单。测试逐块保存、重开 Task，删除临时证据缓存副本后再次读取，检查恢复仅列出未完成块。源证据与实际音频缓存保留。翻译批次测试只验证持久化与编辑保护，使用测试数据，不调用网络服务。

## 原生顺序队列验证

```sh
VOXLINE_QUEUE_MEDIA="/absolute/path/S001-30s.mp4" \
VOXLINE_QUEUE_AUDIO="/absolute/path/S001-30s.wav" \
VOXLINE_MODEL_DIRECTORY="/absolute/path/Models" \
swift test --filter nativeMediaAndWhisperPipelinePersistsRealBatchResults
```

使用已安装模型和同源 S001 的 30 秒视频与音频，建立缺少书签的视频、正常视频和正常音频三个条目。缺失项明确失败后继续处理其余两项，经本机书签解析、身份检查、PCM 提取、真实推理、字幕切分与 Task 保存后重开，核对两份媒体的六句原文和起点差；随后重新关联缺失项并重试，保持其他媒体及人工原文编辑，导出原文 SRT。产物位于忽略目录 tmp/queue-validation；默认测试跳过此入口。此验证不代替长视频、网络翻译或人工字幕质量验收。普通队列测试在外部调用边界控制返回顺序与取消时机，验证失败隔离、取消等待、恢复跳过成功块、校对冲突和写入失败；产品始终使用原生处理链路。

## 翻译协议与本地凭据验证

```sh
swift test --filter 'SubtitleTranslationTests|TranslationServiceStoreTests'
VOXLINE_KEYCHAIN_TEST=1 swift test --filter realKeychainRoundTripKeepsCredentialOutOfMetadata
```

普通测试使用隔离的网络／凭据边界，验证 ID、上下文容量、HTTP 错误、批次恢复、明文迁移和配置保存失败保护。Keychain 可选入口只读写随机测试服务名下的测试字符串，完成后删除测试项，不访问实际服务密钥。真实连接在应用服务页使用当前模型验证；任务验收使用明确选择的服务与字幕文本。

客户端独立真实验收需要指定服务元数据文件，并通过终端隐藏输入提供测试密钥；配置文件和验证产物均不包含密钥：

```sh
read -s VOXLINE_TRANSLATION_API_KEY
export VOXLINE_TRANSLATION_API_KEY
VOXLINE_TRANSLATION_SERVICE_FILE="/absolute/path/TranslationServices.json" \
  swift test --filter realConfiguredServiceTranslatesSubtitleIDs
unset VOXLINE_TRANSLATION_API_KEY
```

使用元数据文件中的首个服务与默认模型，将短字幕翻译为简体中文；只核验实际协议、ID 和结果，不替代人工质量验收。测试会调用所选外部服务，产物位于忽略目录 tmp/translation-validation。默认测试跳过真实网络和 Keychain 入口。

## 播放与字幕定位

```sh
swift test --filter 'MediaPlaybackControllerTests|SubtitleTimeOffsetTests'
```

默认验证真实 AVPlayer 的准备、播放、暂停、结束、定位、所选音轨、媒体失败与释放，以及完整时间轴的原子偏移。页面验收使用已保存 Task 和对应原媒体，在应用中核对画面、字幕预览、定位、编辑提交和保存失败后的草稿；控制器测试通过不能代替原生页面与文件选择器验收。

## 字幕烧录验证

```sh
swift test --filter 'SubtitleBurnInTests|SubtitleExporterTests|MediaPlaybackControllerTests'
VOXLINE_BURN_IN_SAMPLE="/absolute/path/S001-30s.mp4" \
VOXLINE_BURN_IN_TASK="/absolute/path/reviewed.voxline" \
VOXLINE_BURN_IN_OUTPUT="$PWD/tmp/burn-in-validation" \
  swift test --filter realSampleProducesThreeSubtitledVideosFromReviewedText
```

普通入口直接编码和解码原生视频，检查字幕前／中／后的帧、源帧时间、方向变换、H.264／HEVC、所选音轨、过期译文、覆盖和实际导出取消。私有入口从已校对 Task 选取片段时长内的完整字幕，生成原文／译文／双语三个 MP4、验收任务与实际耗时／磁盘数据；不重复转写或调用翻译服务。输出目录中的同名测试样本会被明确替换。播放器人工验收读取生成的 MP4，不能用测试通过代替实机结果。
