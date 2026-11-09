# mmBrowser

自用的多环境浏览器管理器（macOS，基于官方 Google Chrome）。方案和进度见 [docs/PLAN.md](docs/PLAN.md)。

## 构建与测试

```bash
swift build
swift test
```

## 命令行（P1 测试入口）

```bash
# 新建环境（代理必填；没有代理时必须显式 --direct）
.build/debug/mmctl create --name 测试1 --proxy 'socks5://user:pass@host:port' --lang en-US --url https://example.com/

# 检测代理出口
.build/debug/mmctl check 1

# 启动（前台运行；Cmd-Q 关浏览器或在终端 Ctrl-C）
.build/debug/mmctl launch 1

# 其它：list / show / set / plan / rm / restore / serve / chrome，用 --help 查看
```

数据目录默认是 `~/Library/Application Support/mmBrowser`，设置环境变量 `MMBROWSER_HOME` 可以换到别处（比如测试时用临时目录）。
