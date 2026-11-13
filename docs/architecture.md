# LiteMux 架构

## 为什么不用 PRD 里的「Swift 壳 + WKWebView + Go 微内核」

PRD v1.0 设计的是 Swift 窗口壳里嵌一个 WKWebView，后端再起一个本地 Go 内核，两者通过 `127.0.0.1` 上的 HTTP/WebSocket 通信。这其实就是 Wave Terminal（Electron + Go 后端）把 Chromium 换成 WebKit 之后的样子。它解决了体积问题，但代价还在：

- 两个运行时、两个进程，中间还要一层 IPC 协议；
- 需要开一个本地端口，再配上 256-bit 令牌来防 CSRF；
- 终端渲染要靠 WebKit 里的 xterm.js；
- 光 Go 二进制本身就有 8–10 MB。

LiteMux 改成**单进程纯 Swift**：

| 层 | 实现 |
| --- | --- |
| 生命周期 / 菜单 | AppKit（`NSApplication` 和手写的 `NSMenu`）。⌘W 只关窗格，Ctrl 键原样透传 |
| 界面外壳 | SwiftUI：侧栏、标签栏、分屏树、状态栏、弹窗，系统材质，自动跟随深浅色 |
| 终端 | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.99：PTY、xterm-256color、truecolor、CJK 宽字符、Metal 渲染 |
| SSH | 直接在 PTY 里跑 `/usr/bin/ssh`，用 `ControlMaster=auto`，控制套接字放在 `~/.ssh/lm/%C` |
| SFTP | `LiteMuxCore` 里自己实现的 SFTP v3 客户端，跑在 `ssh -s … sftp` 的管道上，请求可以流水线并发 |
| 状态探针 | 每台主机一个常驻的远端 `sh`（走同一条复用隧道），每 5 秒写一次探针脚本 |
| 密码 | 用 Security.framework 读写钥匙串。App 的可执行文件同时兼任 `SSH_ASKPASS` 助手 |

PRD 第 5.2 节第 5 条（本地回环令牌、防 CSRF）在这个架构下已经不需要了，因为根本不开端口。退出时会结束 PTY 子进程，并对 `~/.ssh/lm` 下的每个套接字执行 `ssh -O exit`。

## 模块

```
Sources/
  LiteMuxCore/            只依赖 Foundation，可单元测试
    SSH/                  ssh_config 解析、粘贴命令解析、ssh 参数构造
    SFTP/                 协议编解码 + 流水线客户端
    Files/                FileEntry、排序、5MB/二进制门限、本地与远程文件系统
    Monitor/              探针脚本与解析（/proc、df、nvidia-smi）
    Workspace/            二叉分屏树、tmux 槽位分配、持久化状态
  LiteMux/                App
    App/                  AppDelegate、菜单、AppModel、ConnectionHub
    Terminal/             TerminalSession（每个窗格一个 PTY）
    Workspace/            标签栏、分屏渲染、空状态
    Sidebar/              主机列表、文件树、传输
    Editor/               NSTextView + 行号栏 + 轻量语法着色
    StatusBar/            采样器（本机走 Mach API，远端走探针）与 24pt 状态栏
```

## 关键机制

**tmux 槽位。** 每个窗格的 `PaneSpec` 都带一个 `slot`，同一台主机上所有打开的窗格里，取最小的未占用编号。远端执行的命令是：

```sh
sh -c 'cd <dir> 2>/dev/null; if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s lm_<slot>; fi; exec "${SHELL:-/bin/sh}" -l'
```

这样不会出现两个窗格挂到同一个会话、画面互相镜像的情况。远端没有 tmux 时会静默回退到登录 Shell。整个过程不执行 `tmux set -g`。槽位会随布局一起保存，所以重开 App 后会回到原来的会话。

**认证复用。** 终端里的 ssh 负责第一次建立 master，密码或 2FA 都在终端里交互输入。后台的 SFTP 和探针带 `BatchMode=yes` 与 `ConnectTimeout=6`，永远不会卡在提示上。`ConnectionHub` 会用 `ssh -O check` 观察 master 什么时候上线，上线后通知文件树和状态栏重试。

**保存的密码。** ssh 启动时带上 `SSH_ASKPASS=<LiteMux 可执行文件>`、`SSH_ASKPASS_REQUIRE=force`，以及 `NumberOfPasswordPrompts=1`。ssh 回调我们时，进程在 `main.swift` 里识别出 askpass 模式，只对密码类提示从钥匙串输出密码，然后在加载任何 UI 之前就退出。密码错了只会试一次，不会触发 fail2ban。

**流式传输。** 下载时最多同时有 16 个 32 KB 的 `READ` 请求在途，按偏移写入文件；上传时同样以 16 个 `WRITE` 为一个窗口。内存占用和文件大小无关。

**编辑保存。** 用 `WRITE|CREAT|TRUNC` 打开原文件，写回同一个 inode，所以文件权限不变。

**Training Pulse。** 每个窗格在有输出时（最多每 0.35 秒一次）读取一次终端当前画面，交给 `LiteMuxCore/Training` 解析。读的是渲染后的画面而不是字节流，所以 tmux 重绘、重新挂载、`\r` 刷新的进度条都不会产生重复点：每条逻辑行只解析一次，点按 epoch/step 定位，重绘只会覆盖原来的点。解析器认识普通 `key=value` 打印、Keras、tqdm/Lightning、Hugging Face 字典、mmdetection、detectron2 和 Ultralytics 表格。检测到训练完成、指标变成 NaN 或进程崩溃时，前台弹 toast，后台发系统通知。上一次运行会作为虚线「幽灵」画在同一张图上，方便对比。整个过程只在本机进行，不在服务器上运行任何东西。

**图片与 mask 预览。** 在文件树点图片会通过 SFTP 读取（5 MB 以内）并在独立窗口中预览，悬停显示像素坐标和值。8 位标签图（类别 id 0、1、2…，普通看图软件里一片黑）会被识别出来并按类别着色，旁边列出每个类别的像素占比；调色板 mask 也能识别。

## 构建与体积

App 没有内嵌任何框架：AppKit、SwiftUI、Security、Metal 都是系统自带的。SwiftTerm 静态链接进来，release 构建会用 `-Osize` 编译并 strip。CI 每次构建都会打印 `.app` 的体积。
