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
