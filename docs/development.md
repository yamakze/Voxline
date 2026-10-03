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

Voxline.xcodeproj 共享 VoxlineIOS scheme。Core 框架直接使用 Sources/VoxlineCore；应用使用 Sources/VoxlineIOS，并复用 Mac 的 TaskDisplayExtensions。无第三方构建工具要求，也不下载或链接 WhisperKit。Xcode 可打开工程进行断点调试与 SwiftUI Preview。

```sh
Scripts/build-ios-ipa.sh
Scripts/build-ios-ipa.sh debug
Scripts/compile_and_run_ios.sh
Scripts/compile_and_run_ios.sh --list
Scripts/compile_and_run_ios.sh <模拟器UDID> release
```

- build-ios-ipa.sh 默认为 release，构建 iPhoneOS 设备包，关闭代码签名，创建全新的 Payload 后替换 build/ios/Voxline-unsigned.ipa。失败不会覆盖上一次 IPA；打包不携带 macOS 扩展属性。
- compile_and_run_ios.sh 默认为 debug，优先选择已启动的 iOS 模拟器，否则选择第一个可用 iPhone。指定 UDID 可切换设备；没有可用 runtime 或参数不合法时明确退出。
- 构建成功后按需启动模拟器、等待开机、安装应用并替换旧进程；保留应用数据。构建失败时不安装、不终止旧应用。
- build-ios.sh 是两者共用的构建入口，分别保留 build/ios/device 和 build/ios/simulator 下的 DerivedData。完整日志为对应目录下的 build.log，包含总耗时和 Build Timing Summary。
- IPA 是设备架构 arm64，不能安装到模拟器。普通真机仍需有效签名；可用现有签名工具处理 IPA，或在 Xcode 的 Signing & Capabilities 中选择开发 Team 后运行。当前没有真机签名或运行证据。

当前 iOS 功能与文件规则见 [架构](architecture/README.md)。

## 缩短反馈时间

1. 日常使用 debug 和固定 DerivedData，保留 .build 与模型缓存；只在需要发布包、性能测量或检查 Release 行为时使用 release。不要把 clean 作为日常构建步骤。
2. UI 调整先用 Xcode Canvas / SwiftUI Preview，再跑目标平台；iOS UI 入口只依赖 Core，避免每次预览都编译推理 SDK。Mac 推理链路接通后继续保持 SDK 集成边界。
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
