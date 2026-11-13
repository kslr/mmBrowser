# mmBrowser

自用的多环境浏览器管理器（macOS，基于官方 Google Chrome）。方案和进度见 [docs/PLAN.md](docs/PLAN.md)。

## 构建与测试

需要 Xcode 26 或更新版本。用 Xcode 打开 `mmBrowser.xcodeproj`，选 `mmBrowser` scheme：⌘R 运行，⌘U 跑测试，Product > Archive 打包。

命令行：

```bash
xcodebuild test -project mmBrowser.xcodeproj -scheme mmBrowser -destination 'platform=macOS'
```

工程包含四个 target：`mmBrowser`（App）、`MMCore`（框架）、`mmctl`（命令行工具，构建时自动放进 `mmBrowser.app/Contents/MacOS/`）、`MMCoreTests`。源码目录是 Xcode 的同步文件夹，新增文件放进对应目录即可，不用改工程。App 的 Info.plist 字段在 target 的 Build Settings 里（`INFOPLIST_KEY_*`），版本号是 `MARKETING_VERSION`；图标在 `Sources/MMApp/Resources/Assets.xcassets`，由 `swift scripts/make-icon.swift` 从原图 `design/icon-source.png` 生成：脚本按 macOS 标准网格重画底板，再把原图对齐放进去。换图标就替换原图再跑一次。

主要视图文件底部有 `#Preview`，用的是 `AppModel.preview`：数据放在临时目录，演示数据和截图自检（`--snapshot`）一样，不会碰正式数据目录。

## CI 与发布

- 每个 PR 都会跑编译、测试和本地化检查（`.github/workflows/ci.yml`）。
- 每次推送到 main 自动发布（`.github/workflows/release.yml`）：先跑同样的测试，通过后用 `xcodebuild` 打 Release 包并创建 GitHub Release。版本号取北京时间当天日期（如 `v2026.11.10`），同一天再发就是 `v2026.11.10.2`。连续推送时，上一次没发完的发布会被取消，只发最新的提交。
- 只打 Apple Silicon（arm64）包。安装包只做了 ad-hoc 签名，下载后第一次要右键选"打开"。

## 命令行（P1 测试入口）

下面的 `mmctl` 指 `mmBrowser.app/Contents/MacOS/mmctl`（Xcode 里 Product > Show Build Folder in Finder，在 `Products/Debug/` 下）。

```bash
# 新建环境（代理必填；没有代理时必须显式 --direct；语言和时区默认跟随出口 IP）
mmctl create --name 测试1 --proxy 'socks5://user:pass@host:port'

# 检测代理出口
mmctl check 1

# 启动（前台运行；Cmd-Q 关浏览器或在终端 Ctrl-C）
mmctl launch 1

# Cookie 导入导出（环境需关闭）
mmctl cookies export 1 cookies.json
mmctl cookies import 1 cookies.json --replace

# 其它：list / show / set / plan / rm / restore / serve / chrome，用 --help 查看
```

数据目录默认是 `~/Library/Application Support/mmBrowser`，设置环境变量 `MMBROWSER_HOME` 可以换到别处（比如测试时用临时目录）。

## 本地化

支持简体中文和英文，跟随系统语言（也可以在"系统设置 > 通用 > 语言与地区"里单独给 mmBrowser 选语言）。

- 翻译在 String Catalog 里：`Sources/MMCore/Resources/Localizable.xcstrings`、`Sources/MMApp/Resources/Localizable.xcstrings`、`Sources/mmctl/Resources/mmctl.xcstrings`（打进 App 包里）。key 用语义命名（如 `list.empty.trash`），规则见 [docs/plans/i18n.md](docs/plans/i18n.md)。
- 代码里用户可见的文字一律写 `L("key")`；带插值时 `L("alert.launchFailed \(name)")` 对应的 key 是 `alert.launchFailed %@`。
- 在 Xcode 里构建时，MMCore 和 App 代码里新写的 `L("...")` 会自动加进对应的 catalog，直接在 catalog 编辑器里填中文。**mmctl 的不会自动加**（它的 catalog 属于 App target），要在 `mmctl.xcstrings` 里手动加 key。
- 界面上不需要翻译的字面量（如 `Text("—")`）在 catalog 里标成 "Don't Translate"。
- 构建后跑 `python3 scripts/check-l10n.py`，检查代码用到但 catalog 里没有的 key、没翻完的条目、占位符不一致，并列出遗留的中文字面量。它默认读 Xcode 最近一次构建的 DerivedData，也可以用 `--derived-data` 指定。CI 里也会跑。
- 临时用英文看界面：Xcode 里 Edit Scheme > Run > Options > App Language 选 English，或命令行 `mmBrowser.app/Contents/MacOS/mmBrowser -AppleLanguages '(en)'`。mmctl 跟随 App 的语言设置，可以用 `defaults write local.mmbrowser AppleLanguages '(en)'` 临时切（用完 `defaults delete local.mmbrowser AppleLanguages`）。

## 许可证

[GPL-3.0](LICENSE)。Copyright (C) 2026 kslr
