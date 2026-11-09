# mmBrowser

自用的多环境浏览器管理器（macOS，基于官方 Google Chrome）。方案和进度见 [docs/PLAN.md](docs/PLAN.md)。

## 构建与测试

```bash
swift build
swift test
```

## 打包应用

```bash
./scripts/build-app.sh
open build/mmBrowser.app
```

生成的 `build/mmBrowser.app` 可以拖进"应用程序"文件夹。命令行工具 `mmctl` 也打包在 `mmBrowser.app/Contents/MacOS/` 里。

## CI 与发布

- 每个 PR 都会跑编译、测试和本地化检查（`.github/workflows/ci.yml`）。
- 每次推送到 main 自动发布（`.github/workflows/release.yml`）：先跑同样的测试，通过后打包并创建 GitHub Release。版本号取北京时间当天日期（如 `v2026.11.10`），同一天再发就是 `v2026.11.10.2`。连续推送时，上一次没发完的发布会被取消，只发最新的提交。
- 只打 Apple Silicon（arm64）包。安装包只做了 ad-hoc 签名，下载后第一次要右键选"打开"。

## 命令行（P1 测试入口）

```bash
# 新建环境（代理必填；没有代理时必须显式 --direct；语言和时区默认跟随出口 IP）
.build/debug/mmctl create --name 测试1 --proxy 'socks5://user:pass@host:port'

# 检测代理出口
.build/debug/mmctl check 1

# 启动（前台运行；Cmd-Q 关浏览器或在终端 Ctrl-C）
.build/debug/mmctl launch 1

# Cookie 导入导出（环境需关闭）
.build/debug/mmctl cookies export 1 cookies.json
.build/debug/mmctl cookies import 1 cookies.json --replace

# 其它：list / show / set / plan / rm / restore / serve / chrome，用 --help 查看
```

数据目录默认是 `~/Library/Application Support/mmBrowser`，设置环境变量 `MMBROWSER_HOME` 可以换到别处（比如测试时用临时目录）。

## 本地化

支持简体中文和英文，跟随系统语言（也可以在"系统设置 > 通用 > 语言与地区"里单独给 mmBrowser 选语言）。

- 翻译在 `Sources/<模块>/Resources/{en,zh-Hans}.lproj/Localizable.strings`，key 用语义命名（如 `list.empty.trash`），规则见 [docs/plans/i18n.md](docs/plans/i18n.md)。
- 代码里用户可见的文字一律写 `L("key")`；带插值时 `L("alert.launchFailed \(name)")` 对应的 key 是 `alert.launchFailed %@`。
- 加完文案跑 `python3 scripts/check-l10n.py`，检查漏翻、两种语言 key 不一致和遗留的中文字面量。
- 临时用英文看界面：`.build/debug/mmBrowser -AppleLanguages '(en)'`。

## 许可证

[GPL-3.0](LICENSE)。Copyright (C) 2026 kslr
