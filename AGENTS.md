# AGENTS.md

本文档供 AI 编程助手快速定位代码边界、Isolate/线程约束与构建校验方式，减少无效检索。

## 1. 架构边界

本项目为 **Flutter 移动端（Android / Android TV / iOS）+ Go 原生核心（CGO FFI）** 独立应用，不包含桌面端与 Web 服务端代码。

- **FFI 唯一边界（`lib/core_bridge.dart` ↔ `native/bridge/main.go` ↔ `native/core/app_runtime.go`）**
  - Go 侧仅导出两个 C 符号：`DuanjuRequest(json) -> json` 与 `DuanjuFree(ptr)`。
  - Android 编译为动态库 `libduanju_core.so`（`DynamicLibrary.open`）；iOS 编译为静态 `DuanjuCore.xcframework` 链入主程序（`DynamicLibrary.process()`）。
  - 新增核心能力须在 `lib/core_bridge.dart`（`NativeRepository`）与 `native/core/app_runtime.go`（`NativeRequest` action 分支）两端同步增补。
  - 编译期全站源常量必须两端一致：Dart `ALL_SOURCES=true`（`lib/app_build.dart`）与 Go `buildAllSources="true"`（`native/core/app_build.go`），启动时 `core_bridge.dart` 会校验并拒绝混装库。
- **Go 核心（`native/core`，单包）**
  - 负责全部站源请求签名、目录解析、缓存、弹幕、分集下载调度与本机 `127.0.0.1` 回环播放代理（`app_stream.go`）。
  - **Go `regexp` 基于 RE2，不支持 `(?=...)` 等前瞻语法**；解析多线路播放列表须使用显式字符串切片定位。
  - 新增站源需同步接入：`provider_huangguo.go`、`provider_media.go`、`app_categories.go`、`app_cover_metadata.go`、`app_runtime.go` 及 `lib/models.dart`（`SourceSite`）。
- **Flutter 逻辑与界面（`lib/`、`lib/ui/`）**
  - `lib/` 顶层为纯逻辑与状态层（只用 `ChangeNotifier`，不引入第三方状态管理框架）：`local_store.dart`（多用户、追剧、历史与备份）、`playback_session.dart`（双 `Player` 预加载与播控状态机）、`dlna_client.dart` / `cast_media.dart` / `cast_media_server.dart`（DLNA 发现、本机解密转流与下一集后台预准备）、`download_*.dart`（`FFmpegKit` 无损转封装 MP4、合并与相册导出）。
  - `lib/ui/` 按功能拆分子目录，通过 `AppScope`（`FormFactor`: `phone` / `pad` / `television`）适配手机竖屏沉浸式上下滑切集、平板分栏与 Android TV 全遥控焦点导航（`focus_ring.dart`）。
  - 本地存储按 `users/<id>/*.json` 分文件原子落盘，备份格式（`schema: 1`）与网页版互通；快照解析拒绝未知键，新增持久化字段须保持旧版兼容。
- **原生宿主层（`android/`、`ios/`）**
  - Android（`com.guoapp`）：`MainActivity.kt`（`duanju/device` MethodChannel：系统画中画 PiP、亮度/方向控制、MediaStore 导出）、`CastForegroundService.kt`（DLNA 投屏期间 `mediaPlayback` 前台服务、WakeLock/WifiLock 与锁屏 `MediaSession` 播控）、`TextInputBridge.kt`（TV 原生输入法桥接）。
  - iOS：`AppDelegate.swift` / `SceneDelegate.swift` 与 `ios/DuanjuCore` CocoaPods 本地静态框架。

## 2. 线程与 Isolate 约束

- **FFI 调用禁止阻塞 UI Isolate**：`DuanjuRequest` 是同步阻塞 C 调用（含网络与磁盘 I/O）。Dart 侧必须通过 `NativeRepository` 在 `Isolate.run` 中执行，并在 `finally` 中释放请求 `Utf8` 内存及调用 `DuanjuFree` 释放返回指针，严禁在主 Isolate 直接调用 `_nativeRequest`。
- **跨 Isolate 数据传递**：传入 `Isolate.run` 闭包的仅限基础类型与纯 JSON Map/String，禁止捕获 `BuildContext`、`ChangeNotifier`、`Player` 或 `MethodChannel` 实例。底层 Go `nativeState` 是进程级 C 内存单例，天然被各短生命周期 Worker Isolate 共享。
- **播放器状态串行化**：`PlaybackSession`（`lib/playback_session.dart`）通过 `_operations` Future 链（`_serialize`）串行化 `media_kit`（libmpv）的打开、切集、预加载切换与投屏挂起/恢复；禁止在 `_serialize` 之外并发操作 `Player` 实例，异步回调更新状态前须检查会话代数与 `disposed`/`mounted`。
- **Go 核心锁边界**：`native/core` 中 `engine.mu` 与 `downloads.mu` 仅保护内存状态映射，严禁持锁发起 HTTP 请求或等待磁盘转码。
- **原生通道线程**：Android `MainActivity.kt` 与 iOS `AppDelegate.swift` 的 `MethodChannel` 回调运行在平台主线程，耗时文件 I/O（如相册导出）须切至后台线程完成后再回主线程返回 `MethodChannel.Result`。

## 3. 构建与校验方式

- **安全与测试红线**：测试一律携带 `--dart-define=DISABLE_REMOTE_IMAGES=true`，禁止在开发测试中下载或解析真实站源海报；严禁提交 `*.keystore`、`*.jks`、`key.properties`、`local.properties`、`jniLibs/`、`*.xcframework`、`build/` 与 `dist/`。
- **Dart 与 Go 静态检查及单元测试**（无需编译 CGO 动态库即可运行）：
  ```bash
  flutter pub get
  dart format --output=none --set-exit-if-changed lib test
  dart analyze --fatal-infos lib test
  flutter test --dart-define=DISABLE_REMOTE_IMAGES=true

  cd native
  gofmt -s -w ./bridge ./core
  go vet ./...
  go test -race ./...
  ```
- **真机调试与正式打包**（`flutter run` 前必须先编译对应平台 Go 核心）：
  ```bash
  # Android 调试核心编译（需配置 ANDROID_HOME 与 NDK 28.2.13676358）
  python scripts/build_native.py --abi arm64-v8a
  flutter run

  # Android Release 分架构打包（输出至 dist/android/，国内网络可加 --cn-mirrors）
  python scripts/build_android.py

  # iOS 核心与未签名 IPA 打包（需在 macOS + Xcode + CocoaPods 环境执行）
  python scripts/build_ios.py --core-only
  python scripts/build_ios.py
  ```
- **发布版本更新**：同步提升 `pubspec.yaml` 的 `version: x.y.z+build`（保持 `+build` 构建号递增以兼容更新检查）。
