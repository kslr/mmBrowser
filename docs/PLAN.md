# mmBrowser 方案（v5，P1 已完成）

自用的多环境浏览器管理器：macOS 原生应用，内核用本机安装的**官方 Google Chrome**，每个环境独立存储、独立代理。管理功能按通用指纹浏览器来做，不只针对某一个平台。

## 1. 已确定的约束

| 项 | 决定 |
|---|---|
| 内核 | 只用官方 Google Chrome（本机 `/Applications/Google Chrome.app`，跟随官方自动更新） |
| 应用形态 | macOS 原生应用，Swift + SwiftUI，最低支持 macOS 14 |
| 规模 | 约 200 个环境，同时运行数量受内存限制（16GB 内存约 8–12 个） |
| 代理 | **一个环境对应一个代理（1:1）**，支持 SOCKS5、HTTP，都可以带账号密码 |
| 密码 | 用 Chrome 自带的密码管理器保存，按环境隔离 |
| 钥匙串 | **整个系统都不使用 macOS 钥匙串**（应用自己和 Chrome 都不用） |
| 指纹 | 适度：保证环境一致性，不在页面里注入 JS 去伪造硬件指纹 |
| 自动化 | 正常启动时不连接 CDP、不开远程调试端口 |

已知且接受的局限：所有环境共用这台 Mac 的真实硬件指纹（Canvas、WebGL、音频、字体、屏幕），平台在技术上能识别出这些环境来自同一台设备。

## 2. 已实测的结论（官方 Chrome 156，macOS 15）

| 能力 | 做法 | 结果 |
|---|---|---|
| 时区 | 启动时设 `TZ=<IANA 时区>` 环境变量 | ✅ |
| `navigator.language(s)`、Accept-Language | `--lang`、`--accept-lang` | ✅ |
| `Intl` locale、日期格式、时区名称 | `-AppleLanguages '(xx-YY)'`（只对当前进程生效） | ✅ 但会多开一个垃圾标签页 |
| 去掉垃圾标签页 | 写成 `-AppleLanguages '("xx-YY", "<")'`：macOS 取第一个语言；Chrome 把它当网址时因含 `<` 判为无效而跳过 | ✅（`(xx, <>)` 会让 Chrome 崩溃，不能用） |
| ~~两步启动~~ | 先 `--no-startup-window` 再转交网址 | ❌ 已放弃：这样启动不会执行"恢复上次会话" |
| 启动时恢复上次会话 | `session.restore_on_startup` 受 Secure Preferences 的 HMAC 保护，直接写文件会被丢弃；改为首次初始化时在无界面 Chrome 的 `chrome://settings` 里调用 `chrome.settingsPrivate.setPref` 写入 | ✅ 重启后恢复全部标签页 |
| 名称、主题色、定位权限、WebRTC 配置、关闭投屏发现 | 直接写 `Preferences` / `Local State`（这些不受完整性校验） | ✅ |
| WebRTC | `--force-webrtc-ip-handling-policy=disable_non_proxied_udp` + 对应配置 | ✅ 候选地址为 0 |
| 定位权限 | `profile.default_content_setting_values.geolocation = 2` | ✅ `denied` |
| 无直连 | 运行中用 `lsof` 检查所有 Chrome 进程 | ✅ 非本机 TCP 0、UDP 0（关闭 Media Router 后 mDNS 也没了） |
| 断开即断网 | 运行中停掉上游 | ✅ 页面报 `ERR_SOCKS_CONNECTION_FAILED`，没有回落直连 |
| 对日常用的 Chrome 的影响 | 只用启动参数和环境变量，不改系统级配置 | ✅ 无影响 |
| 不用钥匙串 | `--use-mock-keychain`：Chrome 改用固定的公开口令 `mock_password` 加密（PBKDF2-SHA1，盐 `saltysalt`，迭代 1003 次，AES-128-CBC，前缀 `v10`；Cookies 库版本 24，明文前面多了 32 字节的域名哈希） | ✅ 已用这个已知密钥解开 Chrome 写入的 Cookie |

副作用：Chrome 自己的界面语言会跟着环境语言走。在 macOS 上界面语言和 `Intl` 来自同一个设置，无法分开。

## 3. 架构

```
┌──────────────────── mmBrowser.app（SwiftUI）────────────────────┐
│  界面层：环境列表 / 编辑表单 / 分组 / 标签 / 代理 / 回收站 / 设置   │
│  菜单栏常驻：关闭主窗口后代理照常工作                              │
├─────────────────────────────────────────────────────────────────┤
│  MMCore（Swift Package，可单独测试）                              │
│   ├─ Store       SQLite（GRDB.swift），文件权限 0600，不用钥匙串    │
│   ├─ ProxyEngine Network.framework，每个运行中的环境一个本地       │
│   │              SOCKS5 入口 → 上游 SOCKS5 / HTTP CONNECT（带认证）│
│   ├─ Launcher    两步启动、环境变量、启动参数、进程跟踪、           │
│   │              切到前台 / 关闭                                  │
│   ├─ ProfileSeed 每次启动前写入 Chrome Preferences（名称、主题色、 │
│   │              定位权限等不受校验的项）                          │
│   ├─ ProfileInitializer 首次离线初始化，写入受校验的项（恢复会话）  │
│   └─ GeoCheck    经由代理查询出口 IP、国家、城市、时区              │
└─────────────────────────────────────────────────────────────────┘
          │ Process（不连接 CDP）
          ▼
   Google Chrome  --user-data-dir=<环境目录>  --proxy-server=socks5://127.0.0.1:<端口>
```

- 数据目录：`~/Library/Application Support/mmBrowser/`（`db.sqlite`、`profiles/<id>/`）。
- 应用不进 App Store、不开沙盒，自己签名在本机用。

### 3.0 存储与加密（不用钥匙串）
- 每个环境**从第一次启动起**就带 `--use-mock-keychain`。中途切换会让已有的密码和 Cookie 解不开，所以这个参数是固定的，不提供开关。
- 带来的好处：
  - 不会弹钥匙串授权窗口；
  - 环境目录拷到另一台 Mac 上，保存的密码和 Cookie 照样能用；
  - 应用可以在环境关闭时**直接读写** Chrome 的 Cookies 和 Login Data 数据库，不需要 CDP。
- 代价：Chrome 数据的加密密钥是公开的，**拿到环境目录的人就能解出密码和 Cookie**，安全性和 Linux 上的 `--password-store=basic` 一样。应用自己的数据库（含代理密码）同样以明文存储、只设 0600 权限，因为 Chrome 数据已经是这个保护级别，单独给代理密码加密意义不大。
- 防护靠：
  - 系统层面开启 FileVault；
  - **可选**：把整个数据目录放进一个用主密码加密的 APFS 磁盘映像（`hdiutil` 创建的 sparsebundle），应用启动时输入主密码挂载，退出时卸载。这样不用钥匙串，也能防止 Mac 被别人打开时数据被拷走。

### 3.1 代理引擎
- 本地入口：`127.0.0.1:0`（随机端口），实现 SOCKS5 无认证的 CONNECT 命令。Chrome 用 SOCKS5 时由代理端解析域名。
- 上游：SOCKS5（RFC 1929 用户名密码认证）或 HTTP（CONNECT 加 Basic 认证）。
- **断开即断网**：启动前先检查连通性和出口信息，失败就不启动；运行中上游断开就直接断网，不回落到直连。
- 防泄漏的启动参数：`--host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1"`、`--force-webrtc-ip-handling-policy=disable_non_proxied_udp`、`--disable-quic`。
- 环境也可以显式设为"直连"（默认关闭，需要手动选，界面上会有明显警告）。
- 唯一性：同一个代理（主机、端口、用户名）只能绑定一个环境；不同环境检测出相同出口 IP 时给出警告。

### 3.2 启动流程（已实现：`BrowserLauncher`）
1. 检查环境没有在运行（Chrome 的 `SingletonLock` 指向的 PID 是否存活）。
2. 启动本地转发入口，经由它检测出口（失败就不启动）；时区为"自动"时取出口 IP 所在时区。
3. 写入 Preferences 种子（不受校验的项）。
4. 首次使用时离线初始化（`ProfileInitializer`）：无界面启动 Chrome，代理指向不存在的端口、禁止本地 DNS，调试端口只监听 127.0.0.1 且只存在一两秒；在 `chrome://settings` 里设置"启动时恢复上次会话"，正常退出后删掉这次的会话记录，写入 `.mm-initialized` 标记（带版本号，以后新增一次性设置可以补跑）。
5. 一步启动：`TZ=... chrome --user-data-dir=... --use-mock-keychain --proxy-server=... [防泄漏参数] --lang=... --accept-lang=... [窗口尺寸] [自定义参数] -AppleLanguages '("lang", "<")' [启动页]`。
   - 启动页默认只在第一次打开环境时传入；之后靠恢复会话（如果每次都传，会在恢复的标签页之外再多开一份）。环境可以设置"每次启动都打开启动页"。
6. 等 `SingletonLock` 指向我们启动的进程，确认它成了这个环境的主进程。
7. 进程退出后立即关闭本地入口。

## 4. 功能清单（按通用指纹浏览器）

### 环境管理
- 列表：序号、名称、分组、标签、代理与出口（IP、国家）、状态、最后打开时间、备注；支持搜索、筛选、排序、多选。
- 新建和编辑：
  - 基本：名称、分组、标签、备注、启动页（可以多个网址）
  - 代理：类型、主机、端口、账号、密码、检测按钮、出口信息
  - 环境参数：语言、时区（自动或手动）、地理位置权限（询问或禁止）、WebRTC 策略、窗口尺寸
  - 高级：自定义 Chrome 启动参数
- 单个操作：启动、关闭、切到前台、复制环境、清除缓存、打开环境目录。
- 批量操作：启动、关闭、移动分组、打标签、修改代理、删除（进回收站）、导出。
- 批量新建：一次建 N 个，套用同一个模板，代理按顺序从导入的列表里分配。
- 导入导出：CSV（名称、分组、标签、备注、代理、启动页、语言、时区）。
- 回收站：软删除，保留 N 天后彻底删除（包括环境目录）。

### 分组与标签
- 分组的增删改、排序；标签的增删改、颜色。

### 代理
- 代理是环境的属性（1:1）。另提供"代理视图"方便集中查看和批量检测：出口 IP、国家、延迟、上次检测时间、到期日（手动填写，到期前提醒）。
- 批量导入代理文本（`socks5://user:pass@host:port`、`host:port:user:pass` 等常见格式），并按顺序分配给选中的环境。

### 运行管理
- 运行中的环境列表，可以切到前台、关闭、全部关闭。
- 同时运行数量上限（可设置，默认 10），超出时提醒。
- 窗口识别：每个环境的 Chrome profile 名称和主题色写入 Preferences，工具栏颜色加名称就能分清。

### Cookie 与扩展（后期）
- Cookie 导入导出（JSON）：环境关闭时，直接读写它的 `Cookies` 数据库（加密密钥已知），不需要启动 Chrome，也不需要 CDP。
- 扩展：官方 Chrome 137 起已不支持 `--load-extension`。改为：在各环境里从 Chrome 应用商店手动安装；或者通过外部扩展 JSON 批量预装（是否能按环境单独生效待验证）。

### 备份与迁移（后期）
- 把单个环境导出为 zip，或从 zip 导入。
- 因为用了 mock keychain，导出的环境在另一台 Mac 上导入后，保存的密码和 Cookie 都能直接使用。导出的 zip 等同于明文密码，要妥善保管（可以选择给 zip 加密码）。

### 暂不做（以后需要再说）
- 本地 API 和自动化接口（以后可以做成按次开启的调试启动模式）。
- 多窗口同步操作。
- 团队协作、云同步。

## 5. 分阶段

| 阶段 | 内容 | 完成标准 |
|---|---|---|
| P1 核心 | MMCore：Store、ProxyEngine、Launcher、ProfileSeed、GeoCheck，外加一个命令行测试入口；补齐第 6 节的验证项 | 命令行能创建并启动环境；browserleaks 和 ipleak 上没有 IP、DNS、WebRTC 泄漏；密码能保存，重启后还在 |
| P2 主界面 | SwiftUI 主窗口：环境列表、编辑表单、分组和标签、启动、关闭、切到前台、代理检测、菜单栏常驻 | 能在界面里完成单个环境的完整使用流程 |
| P3 批量 | 批量新建和编辑、CSV 导入导出、代理批量导入和分配、回收站、复制环境、运行数量上限 | 能在几分钟内导入 200 个环境 |
| P4 进阶 | Cookie 导入导出、扩展批量预装、环境备份和迁移、窗口排列 | 视需要 |

## 6. P1 验证项状态

| # | 项目 | 状态 |
|---|---|---|
| 1 | mock keychain 下密码管理器保存、自动填充，重启后还在 | ⏳ 需要手动在界面上操作确认 |
| 2 | profile 名称和主题色生效 | ✅ 配置保留、新标签页已按主题色着色；⏳ 工具栏颜色和头像菜单里的名称需要肉眼确认 |
| 3 | 定位权限默认禁止 | ✅ |
| 4 | WebRTC 只走代理 | ✅ |
| 5 | 外部扩展 JSON 按环境生效 | 移到 P4 |
| 6 | 会话恢复与启动页 | ✅ 改为一步启动 + 首次离线初始化（见 3.2） |

## 7. P1 交付内容

- `Sources/MMCore`：Store（GRDB）、ProxyEngine（本地 SOCKS5 入口 → 上游 SOCKS5 / HTTP CONNECT / 直连）、GeoCheck、ProfileSeed、ProfileInitializer、LaunchPlan、BrowserLauncher、RunningBrowser。
- `Sources/mmctl`：命令行测试入口（create / list / show / set / check / launch / plan / rm / restore / serve / chrome）。
- `Tests/MMCoreTests`：19 个测试，覆盖代理解析、存储约束、代理链路（含认证失败、上游不可达、停止时切断隧道）、启动参数和配置种子。
- 测试时可以用 `MMBROWSER_HOME` 指向临时目录，不影响正式数据。
