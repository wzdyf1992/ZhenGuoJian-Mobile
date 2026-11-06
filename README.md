# 真果鉴 · 移动端 (ZhenGuoJian-Mobile)

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.47%2B-02569B.svg)](https://flutter.dev/)
[![Go](https://img.shields.io/badge/Go%20FFI-1.24%2B-00ADD8.svg)](https://go.dev/)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20Android%20TV%20%7C%20iOS-3DDC84.svg)](#安装说明)

**真果鉴移动端**是一款基于 **Flutter + Go 原生核心（CGO FFI）** 构建的独立短剧与影视客户端，专为 **Android 手机 / 平板、Android TV 大屏与 iOS（iPhone / iPad）** 打造。站源请求、签名解析、本机流解密代理及离线下载转码均在设备本地独立完成，不依赖远程自建后端。

> 单文件跨平台自托管网页版见姐妹仓库：[**ZhenGuoJian-Web**](https://github.com/wzdyf1992/ZhenGuoJian-Web)。两个项目的备份文件（`schema: 1`）完全互通。

---

## 核心特性

- **多形态自适应界面**：
  - **手机端**：底部导航栏，竖屏短剧上下翻页沉浸式切集（左右滑快进快退、长按 2 倍速、画面锁定），横屏剧集竖拿时视频在上、简介选集在下，旋转横屏自动全屏（左侧上下滑调亮度、右侧上下滑调系统音量、两侧双击快退/快进）。
  - **平板端**：可折叠侧边导航栏与分栏详情页，竖拿同手机交互、横拿分栏选集。
  - **Android TV 电视端**：顶部 Tab 与全遥控器焦点平滑导航、电视过扫描安全边距、拼音首字母软键盘搜索，隐藏播控时左右键快进/快退 10 秒。
- **全站源聚合与预缓冲播放**：
  - 内置 11 个短剧 / 影视 / 番剧站源，支持管理员在「设置 › 站源」逐个开关，支持联想搜索与多季剧集检索。
  - 基于 `media_kit`（libmpv）硬件解码 + 本机 Go 播放代理，进入详情页与播放当前集时自动后台预缓冲下一集，支持红果分段滚动弹幕、Android 系统画中画（PiP）小窗播放。
- **DLNA / UPnP 局域网投屏**：
  - 手机与平板播放页一键搜索同一局域网（自动过滤 VPN / 虚拟网卡并匹配网段）的智能电视、盒子或投屏接收端（如 [NextScreen](https://github.com/wzdyf1992/NextScreen)）。
  - 红果等加密视频先在本机无损解密或兼容转封装为标准 MP4 后推送给电视；播放当前集时后台自动预解析并准备下一集实现秒切连播。
  - Android 端内置 `mediaPlayback` 前台媒体服务、唤醒锁与系统 `MediaSession` 锁屏/通知栏快捷播控，避免手机锁屏后断流（基础投屏已真机验证，锁屏保活与下一集后台预准备标为开发快照，待多机型复验）。
- **离线下载、转码导出与多集合并**：
  - 支持点选、拖选与全选批量缓存剧集，每集下载完成后经 `FFmpegKit` 自动解密无损转封装为独立 `.mp4` 文件。
  - 支持将单集导出至系统 `Movies/剧名/` 相册公开目录，或将多集按序无损合并为单个 `.mp4` 视频。
- **多用户权限与备份迁移**：
  - 支持多用户独立保存追剧更新提醒、观看记录与搜索历史；管理员可配置访问密码（3–32 位）、可用站源与下载权限。
  - 支持导出 / 恢复 `.json` 备份（含主题色与偏好设置），与网页版完全互通。

---

## 内置站源

| 站源 | 内容范围 | 搜索方式 |
| --- | --- | --- |
| 红果 | 短剧、漫剧、AI 剧；推荐混排流、榜单、题材筛选 | 在线搜索（含联想词与多季匹配） |
| 韩小圈 | 韩剧、韩国电影、综艺、动漫，多线路切换 | 在线搜索 |
| 鬼片 | 恐怖片、电视剧、动漫，多线路切换 | 匹配站点 RSS 最新条目 |
| 青空 | 番剧、剧场动画、特摄 | 在线搜索 |
| 黄豆 | 精选短剧、榜单 | 本机目录缓存检索 |
| 剧果 | 热门、最新、分类短剧 | 在线搜索 |
| 野果 | 分类短剧 | 在线搜索 |
| 帝果 | 分类视频 | 在线搜索 |
| 黄果视频 / 黄果 AI / 黄果旧版 | 视频剧集、AI 短剧与旧版剧库 | 黄果 AI 在线搜索，其余检索本机缓存 |

> 站源可用性、清晰度与区域限制取决于源站及所处网络环境；应用不解除源站 VIP 或其他授权限制。

---

## 安装说明

前往 [**Releases**](https://github.com/wzdyf1992/ZhenGuoJian-Mobile/releases) 下载对应设备的安装包：

| 平台 | 安装包说明 |
| --- | --- |
| **Android 7.0+**（手机 / 平板 / TV） | 提供 `arm64-v8a`（主流手机平板推荐）、`armeabi-v7a`（智能电视/盒子推荐）、`x86_64`（模拟器）三种架构 APK；若提示 `INSTALL_FAILED_NO_MATCHING_ABIS`，请更换匹配设备架构的 APK |
| **iOS 15.1+**（iPhone / iPad） | 提供未签名 `*-ios-unsigned.ipa`，可通过自签证书或 TrollStore / SideStore / Sideloadly 等工具安装（iOS 端部分手势与导出能力标为开发快照） |

---

## 本地编译构建

### 环境要求

- **Flutter**：`3.47+`（Dart `3.12+`）
- **Go**：`1.24.1+`
- **Python**：`3.10+`
- **Android 构建**：JDK `17`、Android SDK `36`、Android NDK `28.2.13676358`
- **iOS 构建**：macOS、完整 Xcode、CocoaPods

### 调试运行

运行 Flutter 前需先编译目标设备架构的 Go 原生核心库：

```bash
# Android（以 arm64-v8a 真机为例）
python scripts/build_native.py --abi arm64-v8a
flutter pub get
flutter run

# iOS（需在 macOS 上执行）
python scripts/build_ios.py --core-only
flutter pub get
flutter run
```

### 打包正式版

```bash
# 构建 Android 全架构 APK（产物位于 dist/android/）
python scripts/build_android.py

# 仅构建指定架构并启用国内依赖镜像
python scripts/build_android.py --abi arm64-v8a --cn-mirrors

# 构建 iOS 未签名 IPA（产物位于 dist/ios/，需在 macOS 执行）
python scripts/build_ios.py
```

> 本地 Android 发布签名可在 `android/key.properties` 配置 `storeFile`、`storePassword`、`keyAlias`、`keyPassword`（已加入 `.gitignore`，不会入库）；未配置时自动回退使用 debug 签名。

### 代码检查与测试

```bash
dart format --output=none --set-exit-if-changed lib test
dart analyze --fatal-infos lib test
flutter test --dart-define=DISABLE_REMOTE_IMAGES=true

cd native
go vet ./...
go test -race ./...
```

---

## 项目结构

```text
ZhenGuoJian-Mobile/
├── lib/                       # Flutter 业务逻辑层（FFI 桥接、站源目录、播放器会话、DLNA 投屏、下载与多用户存储）
│   └── ui/                    # 自适应界面层（主题、手机/平板/TV 导航壳、发现、详情、播放器、投屏页、下载与设置）
├── native/
│   ├── bridge/                # CGO C-ABI 导出层（DuanjuRequest / DuanjuFree）
│   └── core/                  # Go 原生核心（多站源解析签名、缓存、本机流代理、弹幕、下载调度）
├── android/                   # Android & Android TV 原生宿主工程（画中画、前台投屏媒体服务、相册导出）
├── ios/                       # iOS / iPadOS 原生宿主工程与 DuanjuCore 静态框架 Pod
├── scripts/                   # Go 原生库编译、Android / iOS 打包与品牌图标生成脚本
├── test/                      # Dart 逻辑层单元测试
├── .github/workflows/         # GitHub Actions 自动化编译与发布工作流
├── pubspec.yaml
└── LICENSE
```

---

## 免责声明

- 本项目仅供个人学习与技术研究。
- 本项目与红果短剧及其他各站源运营方无任何关联，未获得其授权或认可；文中涉及的名称与商标归各自权利人所有。
- 应用本身不存储、不上传、不分发任何影视内容，所有数据均由设备端直接请求第三方站点获取，版权归原权利人所有；应用不解除源站 VIP 或其他授权限制。
- 使用者应遵守所在地法律法规及各站点服务条款，因使用本项目产生的一切后果由使用者自行承担。

---

## 开源协议与致谢

本项目改编自 [fish2018](https://github.com/fish2018) 的开源代码，整体以 [**GNU General Public License v3.0 (GPL-3.0)**](LICENSE) 协议发布。第三方依赖（如 `media_kit`、`FFmpegKit` 等）遵循各自的开源许可证。
