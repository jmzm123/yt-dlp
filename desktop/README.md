# 林序下载器 · macOS

这是 `jmzm123/yt-dlp` 的个人 macOS 窗口，基于 yt-dlp 下载引擎。原版命令行功能保持可用。

## 使用

双击 **林序下载器.app**，把视频链接或整段分享文案（支持一次粘贴多条，比如抖音、B站的转发文案）粘进输入框，应用会自动清洗并识别其中的全部链接。选择清晰度和文件夹，点击“开始下载”。队列逐个下载，可以单独取消、重试，也可以全部取消；完成后可以播放视频或在 Finder 中显示，左侧保留最近下载记录。

- 抖音口令/分享文案里的乱码、话题标签、中文说明会自动剥离，只取真正的链接。
- 普通网站使用应用内的 yt-dlp 源码下载。
- 抖音直接下载失败时，自动通过 Ego Lite 浏览器读取同一视频页面提供的 MP4 地址。同一批队列里的连续抖音下载复用同一个浏览器标签（下完批量统一关闭），第二条起明显更快。需要用户登录、验证或接管时会暂停队列；处理后点击该条目的“继续下载”。
- B站清晰度以网站实际提供的为准：选择了高清晰度但实际到手的文件更低时，完成条目会标注实际分辨率，并提示可勾选“使用 Chrome 登录状态”解锁。
- “使用 Chrome 登录状态”默认关闭。仅在勾选时读取本机 Chrome Cookie，Cookie 不会另存成文件；读取失败（如 Chrome 未运行过或数据库被占用）时自动改为不携带登录状态重试，不会导致下载失败。
- 历史记录和保存目录只存放在本机的应用偏好设置中。
- 清晰度以网站提供的文件为准，不做分辨率放大。

## 在自己的 Mac 构建

需要 macOS 13 或更新版本、Xcode（仅 Command Line Tools 无法编译 SwiftUI 宏）、Python 3.11+、ffmpeg。抖音浏览器下载额外需要已安装并可用的 `ego-browser`（Ego Lite）。本项目不安装或接管浏览器。

```bash
brew install python ffmpeg
bash desktop/build.sh
open 'desktop/dist/林序下载器.app'
```

也可以指定输出目录：`bash desktop/build.sh /绝对路径/输出目录`。

应用带有当前分支的 `yt_dlp` Python 源码，但仍使用本机 Python、ffmpeg 和 Ego Lite。它是本机签名的个人构建，未做 Apple 公证，尚不是适合跨机器分发的独立安装包。

## 开发

- `DownloadApp.swift`：原生 SwiftUI 浅色窗口、批量下载队列、进度和历史记录。
- `worker.py`：链接清洗（`extract_urls`）、参数校验、JSON 事件、yt-dlp 下载和文件检查。
- `douyin.js`：Ego Lite 浏览器读取及抖音文件下载。配置随脚本注入，不经过浏览器服务的环境变量（那里的 env 是常驻的，会在批量下载时串任务）。`keepSpace` 开启时下载成功后保留任务空间（发出 `spaceKept` 事件）供队列中下一条抖音复用；应用侧在队列排空、全部取消或退出时通过 `worker.py --close-space <id>` 统一关闭。被用户接管（handOff）的空间绝不再复用。
- `make_icon.swift`：生成应用图标，由 `build.sh` 调用。
- `build.sh`：构建 `.app`。

```bash
python3 -m unittest discover -s desktop/tests -v
python3 desktop/worker.py --url '视频链接' --output "$HOME/Downloads"
```

无头冒烟测试：`林序下载器.app/Contents/MacOS/LinxuDownloader --ui-test --auto-start` 会预填示例乱文案并自动开始真实批量下载（事件打印到 stdout，前缀 `DBG:`）。

在 `macos-gui` 分支开发。`origin` 指向个人仓库，`upstream` 指向 `yt-dlp/yt-dlp`。

```bash
git fetch upstream
git merge upstream/master
bash desktop/build.sh
```
