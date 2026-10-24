---
name: linxu-video-download
description: 使用本机林序下载器（yt-dlp）把视频链接或分享文案下载为本地文件，支持 YouTube、B站、抖音及 yt-dlp 支持的网站，包含抖音浏览器兜底。用户要求下载视频、保存链接中的视频或为当前任务获取指定视频素材时使用；不负责发布视频或抓取未指定范围的整站内容。
---

# 林序视频下载

直接运行本机已有的命令行入口，无需启动桌面窗口。优先使用 worker：它提供分享文案清洗、清晰度限制、抖音浏览器兜底、文件检查和 JSON 结果。

## 入口与环境

- 源码入口：仓库根目录下的 `desktop/worker.py`，源码包目录为仓库根目录。
- 在已确认的源码仓库内运行 `LINXU_SOURCE_ROOT="$(git rev-parse --show-toplevel)"`，并确认该目录下存在 `desktop/worker.py`。从其他目录调用时，将 `LINXU_SOURCE_ROOT` 设置为实际源码根目录的绝对路径。
- 如果源码入口不存在，使用 `/Applications/林序下载器.app/Contents/Resources/worker.py`，原版 CLI 的包目录则改为该 `Resources` 目录。
- Python：优先使用 `"$HOME/.local/bin/python3"`（若存在且依赖齐全），否则选择已安装所需依赖的 `python3`，将解释器绝对路径保存为 `LINXU_PYTHON`。
- 子进程需要 PATH 包含 `"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"`；确认其中能找到 ffmpeg、ffprobe、Deno 和 ego-browser。
- 设置 `PYTHONDONTWRITEBYTECODE=1`，避免在已签名的应用包里生成 Python 缓存。

第一次使用或出现环境错误时，确认入口和 `ffmpeg`、`ffprobe` 可用。YouTube 还使用 Deno 和 `yt-dlp-ejs`。按实际缺失项处理，不要为了下载自动更新源码、重建应用或修改系统 Python。

## 普通下载

用户指定目录时遵从指定；为当前项目获取素材时放到项目合适的素材目录；没有项目语境时默认 `$HOME/Downloads/林序下载器`。使用绝对路径。

```bash
env PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  PYTHONDONTWRITEBYTECODE=1 \
  "$LINXU_PYTHON" \
  "$LINXU_SOURCE_ROOT/desktop/worker.py" \
  --url '视频链接或只包含一个链接的分享文案' \
  --output '/绝对路径/素材目录' --quality best
```

`--quality` 只接受 `best`、`1080`、`720`，默认 `best`。指定的是清晰度上限，实际文件可能更低，不做放大。链接、文案和目录应作为独立的进程参数传入；通过 Python 调用时使用 `subprocess.run([...])`，不要使用 `shell=True` 或拼接用户文本到 shell 代码。

worker 默认不下载整个播放列表，也不读取 Chrome Cookie。需要登录状态时，可根据用户已经授权的账户使用范围添加 `--chrome-cookies`；不要把 Cookie 或临时 CDN 地址写进交付记录。Chrome Cookie 读取失败时 worker 会自动尝试无登录下载，结果仍可能达不到所选清晰度。

## 多链接与分享文案

worker 每次接受一个链接。多条输入按顺序逐条运行；可调用现有清洗函数提取、去重，而无需自行猜测文案里的 URL 边界：

先将 `LINXU_SOURCE_ROOT` 导出到子进程环境（`export LINXU_SOURCE_ROOT`）。

```python
import importlib.util
import os
from pathlib import Path

worker_path = Path(os.environ["LINXU_SOURCE_ROOT"]) / "desktop" / "worker.py"
spec = importlib.util.spec_from_file_location('linxu_worker', worker_path)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
urls = worker.extract_urls(share_text)  # share_text 为用户原始输入
```

源码不存在时，将 `worker_path` 改为应用包入口。普通批量不使用 `--keep-space`，让每条抖音任务自动清理自己的浏览器空间；不要额外实现浏览器空间复用。某条失败时记录原因，可继续处理其他独立链接；遇到用户接管浏览器时暂停抖音批次。

## 抖音浏览器兜底

抖音直接下载失败后，worker 会自行调用已安装的 `ego-browser` 读取视频页面并下载，无需 Agent 自行抓取媒体地址。首次处理抖音前运行 `ego-browser skill`，读取完整指南；需要手动操作浏览器时遵循该指南。

当输出出现 `browserHandoff`，或错误提示登录、验证码、用户控制、ownership/inactive 时：停止自动重试，告诉用户需要处理浏览器提示，保留对应空间供用户操作。用户处理完并明确让 Agent 继续后，可使用此次 `browserSpace.id` 添加 `--browser-space <id>` 恢复；该选项会跳过直接下载并尝试接回空间。若仍被拒绝控制，停止并报告，不要反复接管或创建新空间绕过提示。

## 结果与交付

stdout 为逐行 JSON：`state`、`title`、`progress`、`log` 是过程事件。必须等待进程结束，退出码为 0 且收到 `complete` 事件，才能报告成功；`error` 或 `cancelled` 不能算成功。

`complete` 包含真实的 `path`、`width`、`height`、`duration`、`size`、`hasAudio`。确认文件存在且非空，使用返回路径，不猜测文件名。worker 已通过 ffprobe 检查视频；仅在文件可疑或用户要求时再做完整解码检查。

交付时给出本地文件链接，按需要注明实际分辨率。批量任务列出成功与失败项；若实际清晰度低于请求，应明确说明。下载本身不代表文件已放入桌面应用的历史记录。不要自动追加转写、发布或删除操作。

## 需要原版 yt-dlp 功能时

列出格式、下载字幕、仅提取音频或用户明确要求播放列表时使用原版 CLI；这些选项不是 worker 参数。使用确定的本地包，避免误用其他全局 yt-dlp 版本：

```bash
env PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  PYTHONDONTWRITEBYTECODE=1 \
  PYTHONPATH="$LINXU_SOURCE_ROOT" \
  "$LINXU_PYTHON" -m yt_dlp \
  --ignore-config --no-playlist -F -- '视频链接'
```

实际下载加 `-P '/绝对路径/目录'` 和 `--no-overwrites`，根据需求选择格式；用户明确要求播放列表时去掉 `--no-playlist`。原版 CLI 不带林序 worker 的抖音浏览器兜底。选项不确定时查看这份本地 CLI 的 `--help`。
