#!/usr/bin/env python3
"""JSON-lines bridge between the macOS window, yt-dlp and the browser fallback."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
CHILD = None
BROWSER_SPACE = None
BROWSER_HANDED_OFF = False


def emit(event, **fields):
    print(json.dumps({'event': event, **fields}, ensure_ascii=False), flush=True)


# URLs are matched against an ASCII-only charset so that Chinese share text
# glued directly onto a link (e.g. "…/abc/复制此链接") stops at the right place.
URL_PATTERN = re.compile(r"https?://[A-Za-z0-9\-._~:/?#@!$&'*+,;=%]+", re.I)
TRAILING_PUNCTUATION = '.,;:!?\'"\\'


def extract_urls(text):
    """Pull every usable video link out of pasted share text, in order."""
    text = text.replace('\\_', '_').replace('\\/', '/')
    urls = []
    for match in URL_PATTERN.finditer(text):
        url = match.group().rstrip(TRAILING_PUNCTUATION)
        parts = urlsplit(url)
        if not parts.hostname or parts.username or parts.password:
            continue
        if url not in urls:
            urls.append(url)
    return urls


def extract_url(text):
    urls = extract_urls(text)
    if not urls:
        raise ValueError('请粘贴视频链接，或包含链接的分享文案。')
    if len(urls) > 1:
        raise ValueError(f'识别到 {len(urls)} 个链接，请粘贴到主窗口批量下载。')
    return urls[0]


def is_douyin(url):
    host = (urlsplit(url).hostname or '').lower()
    return host == 'douyin.com' or host.endswith('.douyin.com')


def cookie_problem(lines):
    """True when yt-dlp failed before downloading because browser cookies were unusable."""
    text = '\n'.join(lines).lower()
    return ('could not find' in text and 'cookies database' in text
            or 'failed to load cookies' in text
            or ('cookie' in text and 'database is locked' in text))


def format_selector(quality):
    limit = '' if quality == 'best' else f'[height<=?{int(quality)}]'
    return f'bv*{limit}+ba/b{limit}'


class Cancelled(Exception):
    pass


def cancel(_signum, _frame):
    if CHILD and CHILD.poll() is None:
        try:
            os.killpg(CHILD.pid, signal.SIGTERM)
            CHILD.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(CHILD.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    raise Cancelled()


def stream_process(args, env, on_line, stdin=None):
    global CHILD
    CHILD = subprocess.Popen(
        args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
        text=True, encoding='utf-8', errors='replace', env=env,
        start_new_session=True, bufsize=1)
    try:
        if stdin is not None:
            CHILD.stdin.write(stdin)
            CHILD.stdin.close()
        for line in CHILD.stdout:
            on_line(line.rstrip())
        return CHILD.wait()
    finally:
        if CHILD.poll() is not None:
            CHILD = None


def probe(path, require_video=True):
    result = subprocess.run([
        shutil.which('ffprobe') or 'ffprobe', '-v', 'error', '-show_entries',
        'format=duration,size:stream=codec_type,width,height', '-of', 'json', str(path),
    ], capture_output=True, text=True, timeout=30, check=True)
    info = json.loads(result.stdout)
    streams = info.get('streams', [])
    video = next((s for s in streams if s.get('codec_type') == 'video'), None)
    if not video and require_video:
        raise ValueError('文件没有可识别的视频画面，请换一个链接重试。')
    return {
        'path': str(path), 'title': path.stem,
        'width': (video or {}).get('width', 0), 'height': (video or {}).get('height', 0),
        'duration': float(info.get('format', {}).get('duration', 0)),
        'size': path.stat().st_size,
        'hasAudio': any(s.get('codec_type') == 'audio' for s in streams),
    }


def download(args):
    global BROWSER_SPACE, BROWSER_HANDED_OFF
    url = extract_url(args.url)
    output = Path(args.output).expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    if not shutil.which('ffprobe') or not shutil.which('ffmpeg'):
        raise ValueError('缺少 ffmpeg。请先在终端运行：brew install ffmpeg')
    env = dict(os.environ)
    package_root = HERE if (HERE / 'yt_dlp').is_dir() else HERE.parent
    env['PYTHONPATH'] = str(package_root)
    env['PYTHONUNBUFFERED'] = '1'
    files = []
    errors = []

    def on_ytdlp(line):
        if line.startswith('GUI_PROGRESS:'):
            try:
                data = json.loads(line.split(':', 1)[1])
                total = data.get('total_bytes') or data.get('total_bytes_estimate') or 0
                done = data.get('downloaded_bytes') or 0
                emit('progress', fraction=min(done / total, 0.99) if total else None,
                     speed=data.get('speed'), eta=data.get('eta'))
            except (ValueError, TypeError):
                pass
        elif line.startswith('GUI_FILE:'):
            files.append(Path(json.loads(line.split(':', 1)[1])).resolve())
        elif line.startswith('GUI_TITLE:'):
            emit('title', title=json.loads(line.split(':', 1)[1]))
        elif line:
            # Keep temporary CDN signatures and credential-like query strings out of UI logs.
            safe = re.sub(r'(https?://[^\s?]+)\?[^\s]+', r'\1?…', line)
            emit('log', text=safe)
            if 'ERROR:' in line:
                errors.append(safe)

    if not args.browser_space:
        emit('state', text='正在读取视频信息…')
        command = [
            sys.executable, '-m', 'yt_dlp', '--ignore-config', '--no-playlist',
            '--newline', '--no-colors', '--progress', '--progress-delta', '0.25',
            '--progress-template', 'download:GUI_PROGRESS:%(progress)j',
            '--print', 'before_dl:GUI_TITLE:%(title)j',
            '--print', 'after_move:GUI_FILE:%(filepath)j', '--no-simulate',
            '--no-overwrites', '--socket-timeout', '20', '--retries', '2',
            '--fragment-retries', '2', '--merge-output-format', 'mp4',
            '-S', 'res,vcodec:h264,acodec:aac', '-f', format_selector(args.quality),
            '-P', str(output), '-o', '%(title).100B [%(id)s].%(ext)s',
        ]

        def run_ytdlp(with_cookies):
            cookies = ['--cookies-from-browser', 'chrome'] if with_cookies else []
            return stream_process(command + cookies + ['--', url], env, on_ytdlp)

        code = run_ytdlp(args.chrome_cookies)
        if code and args.chrome_cookies and cookie_problem(errors):
            # A locked/missing Chrome profile must not fail an otherwise fine download.
            emit('log', text='读取 Chrome 登录状态失败，改为不携带登录状态重试…')
            emit('state', text='未读取到 Chrome 登录状态，正在重试…')
            errors.clear()
            files.clear()
            code = run_ytdlp(False)
    else:
        code = 1

    if code and is_douyin(url):
        browser = shutil.which('ego-browser')
        if not browser:
            raise ValueError('抖音拒绝了直接下载。自动浏览器下载需要这台 Mac 安装 ego-browser。')
        emit('state', text='正在用浏览器读取抖音视频…')
        # The ego-browser node runtime shares the long-lived browser service's
        # process.env, so values passed through the environment would go stale
        # between downloads. Embed the per-run config into the script instead.
        config = json.dumps({'url': url, 'output': str(output), 'quality': args.quality,
                             'resumeSpace': args.browser_space,
                             'keepSpace': args.keep_space}, ensure_ascii=False)
        script = f'const LINXU_DOWNLOAD_CONFIG = {json.dumps(config)};\n'
        script += (HERE / 'douyin.js').read_text()
        browser_error = []

        def on_browser(line):
            global BROWSER_SPACE, BROWSER_HANDED_OFF
            if line.startswith('GUI_EVENT:'):
                data = json.loads(line[len('GUI_EVENT:'):])
                event = data.pop('event')
                if event == 'browserSpace':
                    BROWSER_SPACE = data['id']
                elif event == 'browserHandoff':
                    BROWSER_HANDED_OFF = True
                elif event == 'downloaded':
                    files.append(Path(data['path']))
                    return
                elif event == 'error':
                    browser_error.append(data.get('text', '浏览器下载失败'))
                    return
                emit(event, **data)
            elif line:
                emit('log', text=line[:600])

        code = stream_process([browser, 'nodejs'], env, on_browser, script)
        if code:
            raise ValueError(browser_error[-1] if browser_error else
                             '浏览器下载未完成。请查看浏览器提示，再点击重试。')
    elif code:
        raise ValueError(errors[-1] if errors else '下载失败，请检查链接及网络后重试。')
    if not files or not files[-1].is_file():
        raise ValueError('下载程序未返回完整文件，请展开详细记录查看原因。')
    emit('state', text='正在检查下载文件…')
    result = probe(files[-1])
    emit('complete', **result)


def close_browser_space(space_id):
    """Finish an agent-owned ego-browser task space. Best effort."""
    browser = shutil.which('ego-browser')
    if not browser:
        return
    script = f'const t=await taskSpace({int(space_id)}); await t.finish({{keep:[]}});'
    try:
        subprocess.run([browser, 'nodejs', '-e', script],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
    except Exception:
        pass


def find_asr_home():
    candidates = []
    if os.environ.get('ASR_SUBTITLE_HOME'):
        candidates.append(Path(os.environ['ASR_SUBTITLE_HOME']))
    candidates.append(Path.home() / 'Documents/Work/linxu/asr_subtitle')
    for home in candidates:
        if (home / '.venv/bin/python').is_file() and (home / 'transcribe.py').is_file():
            return home
    return None


def wrap_paragraphs(text, width=180):
    """把连续转写文本按硬标点断句后分组为适合阅读的 Markdown 段落。"""
    sentences = [s for s in re.split(r'(?<=[。！？；!?;])', text) if s.strip()]
    paragraphs, current = [], ''
    for sentence in sentences:
        current += sentence
        if len(current) >= width:
            paragraphs.append(current.strip())
            current = ''
    if current.strip():
        paragraphs.append(current.strip())
    return '\n\n'.join(paragraphs)


def transcribe(args):
    path = Path(args.transcribe).expanduser().resolve()
    if not path.is_file():
        raise ValueError('文件不存在或已被移动。')
    info = probe(path, require_video=False)
    if not info['hasAudio']:
        raise ValueError('这个文件没有音轨，无法转写文字稿。')
    asr_home = find_asr_home()
    if not asr_home:
        raise ValueError('未找到语音转写工具 asr_subtitle（期望在 ~/Documents/Work/linxu/asr_subtitle）。')
    tmpdir = Path(tempfile.mkdtemp(prefix='linxu-asr-'))
    emit('state', text='正在加载语音识别模型…')

    def on_line(line):
        emit('log', text=line[:600])
        if '模型就绪' in line:
            emit('state', text='正在识别语音（约需一分钟）…')
        match = re.search(r'转写 第 (\d+)/(\d+) 块', line)
        if match:
            emit('progress', fraction=0.6 * int(match[1]) / int(match[2]))
            return
        match = re.search(r'对齐 第 (\d+)/(\d+) 块', line)
        if match:
            emit('progress', fraction=0.6 + 0.4 * int(match[1]) / int(match[2]))

    code = stream_process(
        [str(asr_home / '.venv/bin/python'), str(asr_home / 'transcribe.py'),
         str(path), '-o', str(tmpdir)],
        dict(os.environ), on_line)
    txt = tmpdir / f'{path.stem}.txt'
    if code or not txt.is_file():
        shutil.rmtree(tmpdir, ignore_errors=True)
        raise ValueError('转写失败，请展开详细记录查看原因。')
    text = txt.read_text(encoding='utf-8').strip()
    shutil.rmtree(tmpdir, ignore_errors=True)
    if not text:
        raise ValueError('没有识别到语音内容（可能是纯音乐或无声视频）。')
    minutes, seconds = divmod(int(info['duration']), 60)
    body = wrap_paragraphs(text)
    markdown = (f'# {path.stem}\n\n'
                f'> 语音转文字稿 · 本机 Qwen3-ASR 离线生成 · 时长 {minutes:02d}:{seconds:02d}\n\n'
                f'{body}\n')
    md_path = path.with_suffix('.md')
    if md_path.exists():
        for suffix in range(1, 100):
            candidate = path.with_name(f'{path.stem} ({suffix}).md')
            if not candidate.exists():
                md_path = candidate
                break
    md_path.write_text(markdown, encoding='utf-8')
    emit('transcribed', path=str(md_path), chars=len(text),
         width=info['width'], height=info['height'], duration=info['duration'],
         size=info['size'], hasAudio=info['hasAudio'])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--url')
    parser.add_argument('--output')
    parser.add_argument('--quality', choices=['best', '1080', '720'], default='best')
    parser.add_argument('--chrome-cookies', action='store_true')
    parser.add_argument('--browser-space', type=int)
    parser.add_argument('--keep-space', action='store_true')
    parser.add_argument('--close-space', type=int)
    parser.add_argument('--transcribe')
    args = parser.parse_args()
    if args.close_space is not None:
        close_browser_space(args.close_space)
        return 0
    if not args.transcribe and (not args.url or not args.output):
        parser.error('--url 和 --output 必填')
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    try:
        if args.transcribe:
            transcribe(args)
        else:
            download(args)
        return 0
    except Cancelled:
        emit('cancelled', text='下载已取消')
        if BROWSER_SPACE and not BROWSER_HANDED_OFF:
            # Close only the agent-owned task created by this download.
            close_browser_space(BROWSER_SPACE)
        return 130
    except Exception as error:
        emit('error', text=str(error))
        return 1


if __name__ == '__main__':
    sys.exit(main())
