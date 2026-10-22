# 开发工作流与测试

工具链：Xcode 26.2 / Swift 6.2；Mac 基线 macOS 15，iOS 基线 iOS 18。

## 命令

```bash
# macOS
make build            # 使用 SwiftPM 编译 Mac 应用包（产物：dist/macos/Voxline.app）
make run              # 编译并在停止旧实例后启动 Mac 应用
make run CONFIGURATION=release  # 使用与发布版相同的优化配置运行
make test             # 运行核心单元测试与工作流测试套件

# iOS
make ios              # 使用 xcodebuild 编译 iOS 模拟器版本
make ios-run          # 启动 iPhone 17 Pro 模拟器、安装并启动 Voxline
make ipa              # 构建未签名的 Release IPA（产物：dist/ios/Voxline-unsigned.ipa）
```

查看所有可用参数：
```bash
make help
```

日常构建默认使用 Debug（`-Onone`）。比较转写速度和 CPU 时使用 Release，并保持模型、语言、媒体范围一致，依次运行，避免两个进程争用 CPU、GPU 和神经网络引擎。模型首次加载耗时与已加载后的转写耗时分别记录。

---

## 构建目录

| 目录 | 职责 |
| --- | --- |
| `.build/` | SwiftPM 依赖、编译产物与增量缓存 |
| `.build/ios/{device,simulator}/` | iOS DerivedData 与构建日志 |
| `.build/packaging/` | App／IPA 组装、发布签名与归档的中间文件 |
| `.build/localization/` | 编译器提取的本地化检查材料 |
| `dist/macos/` | 可运行的 `Voxline.app` 及身份信息 |
| `dist/ios/` | 未签名 `Voxline-unsigned.ipa` 及身份信息 |
| `dist/release/` | 带版本号的 ZIP／IPA、更新 feed、说明与校验和 |

清除 `.build/` 后，后续构建需重新准备依赖并编译。

构建与运行脚本集中在 `Scripts/` 目录：

| 脚本 | 职责与产物说明 |
| --- | --- |
| `Scripts/build-app.sh` | 编译 Mac SwiftPM 产物、组装 App Bundle、复制模块资源并执行代码签名 |
| `Scripts/compile_and_run.sh` | 编译 Mac 应用，平滑重启旧进程并前台运行新产物 |
| `Scripts/build-ios.sh` | 统一的 iOS xcodebuild 入口，复用固定的 DerivedData 缓存 |
| `Scripts/build-ios-ipa.sh` | 构建 iOS 真机架构 arm64 产物，生成未签名 Payload 与 `Voxline-unsigned.ipa` |
| `Scripts/compile_and_run_ios.sh` | 编译、安装并启动指定或默认 iOS 模拟器（默认 iPhone 17 Pro） |
| `Scripts/check-localization.py` | 核对编译器提取的本地化键与模块中英资源文件一致性 |
| `Scripts/capture-ui.swift` | Mac 原生页面遍历与 iOS Simulator 截图，生成 PNG、页面清单与 HTML 图册 |

### Mac 页面截图

截图脚本需要 macOS 15.2 或更新版本。先运行 `make run`，选择已有可播放视频且带字幕的任务：

```bash
swift Scripts/capture-ui.swift --task "任务名称"
```

截图保存在忽略的 `tmp/ui-captures/macos-<时间>/`，通过 `index.html` 查看，`manifest.json` 记录已捕获页面及不可用原因。脚本在新标签页中遍历任务、服务、设置（包括外观）和校对弹窗；只打开编辑页并取消，不保存、删除、开始处理或执行导出。完成后关闭截图标签页。

首次运行需为实际运行脚本的终端／Codex 授予 macOS“辅助功能”和“屏幕录制”权限：

```bash
swift Scripts/capture-ui.swift --permissions
swift Scripts/capture-ui.swift --request-permissions
```

系统授权完成后重新启动终端再运行。`--current` 仅捕获当前 Voxline 窗口；`--app` 指定运行中的 App 路径，`--output` 指定图册目录，`--help` 查看全部参数。采集期间保持 Mac 解锁，暂不操作 Voxline。

### iOS 页面截图

先用 `make ios-run` 启动 iPhone 17 Pro，在 Voxline 中打开目标页面，再保存当前模拟器画面：

```bash
swift Scripts/capture-ui.swift --platform ios --page task-library --output tmp/ui-captures/ios
# 切换页面后继续追加到同一图册
swift Scripts/capture-ui.swift --platform ios --page proofreading --output tmp/ui-captures/ios
```

iOS 截图使用 `simctl io screenshot`，不需要 Mac 屏幕录制或辅助功能权限，也不会操作应用数据。默认选择已启动的 iPhone 17 Pro；`--list-devices` 列出设备，`--device UUID` 指定其他已启动模拟器。`--page` 指定 PNG 名称，同名页面更新原截图；同一目录中的其他页面保留。iOS 页面由手动导航，Mac 默认执行自动遍历；Mac 也可用 `--page` 追加当前窗口截图。

---

## 代码签名与标识

### macOS 签名
日常 Mac 开发使用系统钥匙串中的有效证书：
- 默认自动检测第一个有效的 `Apple Development` 或 `Developer ID Application` 证书，并将 SHA-1 缓存在 `.local/mac-signing.json`。
- CI 环境或无证书环境可通过环境变量设置 ad-hoc 签名：
  ```bash
  VOXLINE_MAC_SIGN_IDENTITY=- Scripts/build-app.sh debug
  ```
- 也可以显式传入指定证书：
  ```bash
  VOXLINE_MAC_SIGN_IDENTITY="Apple Development: <证书名>" Scripts/build-app.sh debug
  ```

### iOS 签名与侧载
- 模拟器构建采用本地临时 ad-hoc 签名，系统提供完整的 Keychain 与模拟文件沙盒支持。
- `build-ios-ipa.sh` 生成的未签名 IPA（`dist/ios/Voxline-unsigned.ipa`）专供个人侧载使用。可通过 [AltStore](https://altstore.io)、[SideStore](https://sidestore.io)、[Sideloadly](https://sideloadly.io) 或 Xcode 使用个人 Apple ID 签名安装。
- **Bundle ID 约定**：Mac Bundle ID 固定为 `dev.voxline.app`，iOS 固定为 `dev.voxline.ios`。版本号在根目录 `Version.xcconfig` 中统一维护。

---

## 测试套件与验证策略

Voxline 遵循模块化分层验证，测试直接对应具体功能边界：

```bash
# 运行全部快速单元测试
swift test

# 按模块或特性过滤测试
swift test --filter ProcessingTaskTests       # Core 任务模型与参数验证
swift test --filter SubtitleSegmentation      # 字幕断句切分逻辑
swift test --filter MediaPlaybackController   # AVPlayer 播放器控制与定位
swift test --filter SubtitleBurnInTests       # Core Image 硬字幕压制
swift test --filter SubtitleEmbeddingTests    # tx3g 软字幕内封封装
swift test --filter SubtitleTranslationTests  # OpenAI 兼容协议与滑动窗口
swift test --filter TaskProcessingQueueTests  # 顺序执行队列生命周期与恢复
```

### iOS 模拟器集成测试
```bash
xcodebuild -project Voxline.xcodeproj -scheme VoxlineIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/ios/simulator/DerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

### 本地化资源校验
通过编译器提取当前源码中调用的本地化 Key，并校验中英文资源完整性：
```bash
swift build --product Voxline -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/.build/localization/mac"
python3 Scripts/check-localization.py .build/localization/mac \
  .build/ios/device/DerivedData/Build/Intermediates.noindex/Voxline.build/Debug-iphoneos
```
