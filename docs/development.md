# 开发工作流与测试

项目工程基线为 Xcode 26.2 与 Swift 6.2，系统运行基线为 macOS 15 与 iOS 18。

## 构建与运行命令

日常构建与测试任务统一通过根目录 `Makefile` 驱动：

```bash
# macOS 应用
make build            # 编译 Mac 应用包（产物：dist/macos/Voxline.app）
make run              # 编译并在前台启动 Mac 应用（自动退出旧进程）
make run CONFIGURATION=release  # 以 Release 优化模式编译并启动
make test             # 执行核心单元测试与工作流测试套件

# iOS 应用
make ios              # 调用 xcodebuild 编译 iOS 模拟器版本
make ios-run          # 启动 iPhone 模拟器并安装运行
make ipa              # 构建未签名的 Release IPA（产物：dist/ios/Voxline-unsigned.ipa）

# 帮助与参数
make help             # 输出完整目标列表与可用变量
```

开发阶段默认使用 Debug 配置。进行 Core ML 推理吞吐率、显存峰值或导出性能测试时，必须使用 Release 模式，并保持单进程串行运行，避免并发争夺硬件加速资源。

## 产物结构与脚本分工

### 目录组织

| 目录路径 | 职责与内容 |
| --- | --- |
| `.build/` | SwiftPM 依赖解析缓存与 macOS 编译中间产物 |
| `.build/ios/` | iOS 平台 DerivedData 缓存与构建日志（区分 `simulator/` 与 `device/`） |
| `.build/packaging/` | 应用组装、发布签名与归档临时目录 |
| `.build/localization/` | 编译器提取的本地化分析材料 |
| `dist/macos/` | 可执行 `Voxline.app` 与签名配置快照 |
| `dist/ios/` | 未签名的 `Voxline-unsigned.ipa` 安装包 |
| `dist/release/` | 包含版本号的发布压缩包、Sparkle appcast feed 与 SHA-256 校验文件 |

### 核心自动化脚本

自动化构建与校验逻辑集中在 `Scripts/` 目录：

- `Scripts/build-app.sh`：编译 macOS 产物，完成 App Bundle 组装、子模块资源拷贝与代码签名。
- `Scripts/compile_and_run.sh`：编译 macOS 应用，平滑终止运行中进程并前台启动新产物。
- `Scripts/build-ios.sh`：iOS 构建入口，基于 `xcodebuild` 驱动并维护独立的 DerivedData 缓存。
- `Scripts/build-ios-ipa.sh`：构建 iOS arm64 架构 Release 产物，组装生成未签名的 `Voxline-unsigned.ipa`。
- `Scripts/compile_and_run_ios.sh`：编译、安装并启动指定 iOS 模拟器（默认 `iPhone 17 Pro`）。
- `Scripts/check-localization.py`：对比源码提取的本地化键名与多语言资源文件，校验翻译完整性。
- `Scripts/capture-ui.swift`：自动化遍历 macOS 界面与截取 iOS 模拟器画面，生成测试图册与 HTML 报告。

## 代码签名与应用标识

### macOS 签名机制

macOS 开发构建自动从系统钥匙串检索可用签名证书：
- 默认检索 `Apple Development` 或 `Developer ID Application` 证书，指纹缓存于 `.local/mac-signing.json`。
- CI 环境或无证书环境可通过环境变量启用 ad-hoc 签名：
  ```bash
  VOXLINE_MAC_SIGN_IDENTITY=- Scripts/build-app.sh debug
  ```
- 亦可通过环境变量显式传入指定证书：
  ```bash
  VOXLINE_MAC_SIGN_IDENTITY="Apple Development: <证书名>" Scripts/build-app.sh debug
  ```

### iOS 签名与侧载机制

- 模拟器构建采用本地临时 ad-hoc 签名，享有完整沙盒与 Keychain 访问权限。
- `make ipa` 生成的 `dist/ios/Voxline-unsigned.ipa` 专供侧载安装，开发者或用户可通过 AltStore、SideStore、Sideloadly 或 Xcode 配合个人 Apple ID 重签名。
- **Bundle ID 与版本**：Mac Bundle ID 为 `dev.voxline.app`，iOS Bundle ID 为 `dev.voxline.ios`。版本号在根目录 `Version.xcconfig`（`MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`）集中声明。

## 质量保证与测试套件

### 单元测试与定向验证

按模块功能边界组织测试，支持通过 `--filter` 执行定向验证：

```bash
# 全量单元测试
swift test

# 核心模块定向测试
swift test --filter ProcessingTaskTests       # 任务模型与参数序列化
swift test --filter SubtitleSegmentation      # 自然断句与标点切分规则
swift test --filter MediaPlaybackController   # 播放控制与毫秒级时间线检索
swift test --filter SubtitleBurnInTests       # Core Image GPU 硬字幕压制
swift test --filter SubtitleEmbeddingTests    # tx3g 软字幕直通封装
swift test --filter SubtitleTranslationTests  # 翻译协议与滑动窗口机制
swift test --filter TaskProcessingQueueTests  # 串行队列调度与断点恢复
```

### iOS 模拟器集成测试

使用 `xcodebuild` 驱动 iOS 模拟器环境测试：

```bash
xcodebuild -project Voxline.xcodeproj -scheme VoxlineIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/ios/simulator/DerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

### 本地化资源完整性校验

静态提取源码中所有 `String(localized:)` 声明，核对资源文件缺失项：

```bash
swift build --product Voxline -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/.build/localization/mac"
python3 Scripts/check-localization.py .build/localization/mac \
  .build/ios/device/DerivedData/Build/Intermediates.noindex/Voxline.build/Debug-iphoneos
```

### UI 截图自动化回归

#### macOS 全量遍历
运行需确保终端具备 macOS「辅助功能」与「屏幕录制」权限：

```bash
# 检查与申请系统权限
swift Scripts/capture-ui.swift --permissions
swift Scripts/capture-ui.swift --request-permissions

# 执行界面遍历捕获
make run
swift Scripts/capture-ui.swift --task "测试任务"
```

产物保存于 `tmp/ui-captures/macos-<时间戳>/`，包含各页面截图、`manifest.json` 与 `index.html`。使用 `--current` 参数可仅捕获当前活动窗口。

#### iOS 模拟器截图
```bash
make ios-run
swift Scripts/capture-ui.swift --platform ios --page task-library --output tmp/ui-captures/ios
swift Scripts/capture-ui.swift --platform ios --page proofreading --output tmp/ui-captures/ios
```
同名页面自动覆盖，其余截图完整保留。
