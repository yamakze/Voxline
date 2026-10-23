# 开发工作流与测试

工具链基线为 Xcode 26.2 与 Swift 6.2。平台支持基线为 macOS 15 与 iOS 18。

## 构建与运行命令

常用任务通过根目录 `Makefile` 组织：

```bash
# macOS
make build            # 编译 Mac 应用包（产物：dist/macos/Voxline.app）
make run              # 编译并启动 Mac 应用（自动终止已运行实例）
make run CONFIGURATION=release  # 使用 Release 优化配置编译并运行
make test             # 执行核心单元测试与工作流测试套件

# iOS
make ios              # 使用 xcodebuild 编译 iOS 模拟器版本
make ios-run          # 启动 iPhone 模拟器、安装并启动 Voxline
make ipa              # 构建未签名的 Release IPA（产物：dist/ios/Voxline-unsigned.ipa）

# 帮助信息
make help             # 查看全部可用命令与构建参数
```

日常开发默认使用 Debug 配置（`-Onone`）。进行模型推理速度或硬件占用评估时使用 Release 配置，并保持模型规格、输入语言与媒体分块参数一致，单进程顺序执行，避免两个实例并发争抢系统统一内存与神经网络引擎。

## 产物结构与脚本分工

### 目录说明

| 目录 | 职责与内容 |
| --- | --- |
| `.build/` | SwiftPM 依赖解析缓存、模块编译中间文件 |
| `.build/ios/` | iOS 平台 DerivedData 缓存与构建日志（区分 `simulator/` 与 `device/`） |
| `.build/packaging/` | 应用组装、发布签名与归档过程的临时目录 |
| `.build/localization/` | 编译器提取的本地化分析材料 |
| `dist/macos/` | 可执行的 `Voxline.app` 与签名配置信息 |
| `dist/ios/` | 未签名的 `Voxline-unsigned.ipa` 包 |
| `dist/release/` | 包含版本号的归档压缩包、更新 feed 与 SHA-256 校验和 |

### 构建脚本分工

核心构建与自动化脚本集中在 `Scripts/` 目录：

- `Scripts/build-app.sh`：编译 macOS SwiftPM 产物，完成 App Bundle 组装、模块资源拷贝与代码签名。
- `Scripts/compile_and_run.sh`：编译 macOS 应用，平滑退出旧进程并在前台启动新构建产物。
- `Scripts/build-ios.sh`：iOS 构建入口，调用 `xcodebuild` 并复用固定的 DerivedData 缓存。
- `Scripts/build-ios-ipa.sh`：构建 iOS arm64 架构 Release 产物，生成未签名 Payload 与 `Voxline-unsigned.ipa`。
- `Scripts/compile_and_run_ios.sh`：编译、安装并启动指定 iOS 模拟器（默认 iPhone 17 Pro）。
- `Scripts/check-localization.py`：对比编译器提取的字符串键与中英资源文件，校验翻译完整性。
- `Scripts/capture-ui.swift`：自动化遍历 macOS 原生视图并捕获 iOS 模拟器画面，生成测试图册与 HTML 报告。

## 代码签名与应用标识

### macOS 签名机制

macOS 开发构建从系统钥匙串检索可用证书：
- 默认自动查找有效的 `Apple Development` 或 `Developer ID Application` 证书，并将证书指纹缓存于 `.local/mac-signing.json`。
- CI 环境或缺少开发者证书时，可通过环境变量启用 ad-hoc 签名：
  ```bash
  VOXLINE_MAC_SIGN_IDENTITY=- Scripts/build-app.sh debug
  ```
- 也可以显式指定证书名称：
  ```bash
  VOXLINE_MAC_SIGN_IDENTITY="Apple Development: <证书名>" Scripts/build-app.sh debug
  ```

### iOS 签名与侧载安装

- 模拟器构建采用本地临时 ad-hoc 签名，系统提供沙盒与 Keychain 支持。
- `make ipa` 生成的 `dist/ios/Voxline-unsigned.ipa` 专供侧载安装。可通过 AltStore、SideStore、Sideloadly 或 Xcode 配合个人 Apple ID 证书进行重签名与安装。
- **Bundle ID 与版本**：Mac Bundle ID 为 `dev.voxline.app`，iOS Bundle ID 为 `dev.voxline.ios`。版本号在根目录 `Version.xcconfig` 中统一维护。

## 测试套件与质量验证

### 单元测试与模块测试

测试按模块功能边界组织，支持通过过滤器执行定向验证：

```bash
# 运行完整单元测试套件
swift test

# 按模块或功能过滤测试
swift test --filter ProcessingTaskTests       # 任务模型与参数验证
swift test --filter SubtitleSegmentation      # 字幕断句与切分规则
swift test --filter MediaPlaybackController   # 播放控制与时间线定位
swift test --filter SubtitleBurnInTests       # Core Image 硬字幕压制
swift test --filter SubtitleEmbeddingTests    # tx3g 软字幕直通封装
swift test --filter SubtitleTranslationTests  # 翻译协议与上下文滑动窗口
swift test --filter TaskProcessingQueueTests  # 执行队列调度与恢复
```

### iOS 模拟器集成测试

通过 `xcodebuild` 驱动 iOS 模拟器测试：

```bash
xcodebuild -project Voxline.xcodeproj -scheme VoxlineIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/ios/simulator/DerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

### 本地化资源校验

提取源码中的 `String(localized:)` 键名并核对资源目录中英文对应情况：

```bash
swift build --product Voxline -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/.build/localization/mac"
python3 Scripts/check-localization.py .build/localization/mac \
  .build/ios/device/DerivedData/Build/Intermediates.noindex/Voxline.build/Debug-iphoneos
```

### UI 截图自动化采集

#### macOS 自动化遍历
运行前需在 macOS「系统设置 → 隐私与安全性」为终端或执行环境授予「辅助功能」和「屏幕录制」权限：

```bash
# 检查与申请系统权限
swift Scripts/capture-ui.swift --permissions
swift Scripts/capture-ui.swift --request-permissions

# 执行全量界面捕获
make run
swift Scripts/capture-ui.swift --task "任务名称"
```

产物保存在 `tmp/ui-captures/macos-<时间戳>/`，包含各页面 PNG 截图、`manifest.json` 与用于快速预览的 `index.html`。脚本仅遍历查看页面，不进行保存、删除或任务调度。使用 `--current` 参数可仅截取当前活动窗口。

#### iOS 模拟器截图
```bash
# 启动模拟器并导航至目标视图后执行截取
make ios-run
swift Scripts/capture-ui.swift --platform ios --page task-library --output tmp/ui-captures/ios
swift Scripts/capture-ui.swift --platform ios --page proofreading --output tmp/ui-captures/ios
```

iOS 截图基于 `xcrun simctl io screenshot` 实现。通过 `--page` 参数指定文件名，同名页面自动覆盖更新，其余保留。
