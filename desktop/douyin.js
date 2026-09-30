// Executed by ego-browser nodejs. No cookies or account tokens are exported.
const fs = await import('node:fs');
const fsp = await import('node:fs/promises');
const path = await import('node:path');
const { pipeline } = await import('node:stream/promises');
const { Transform, Readable } = await import('node:stream');
const config = JSON.parse(LINXU_DOWNLOAD_CONFIG);
const emit = (event, fields = {}) => console.log('GUI_EVENT:' + JSON.stringify({ event, ...fields }));
let task;
let part;
let completed = false;
try {
  task = config.resumeSpace
    ? await takeOverTaskSpace(config.resumeSpace)
    // Unique name: a space handed off to the user stays user-owned, and reusing
    // a fixed name would poison every later download in the queue.
    : await taskSpace(`林序下载器 · 抖音视频 · ${Date.now()}`);
  emit('browserSpace', { id: task.spaceId });
  const page = task.page('p1');
  await page.cdp('Network.enable', { maxTotalBufferSize: 12_000_000, maxResourceBufferSize: 3_000_000 });
  await page.goto(config.url);
  let detail;
  const requests = new Set();
  const started = Date.now();
  while (!detail && Date.now() - started < 30_000) {
    const events = await page.events();
    for (const event of events) {
      const p = event.params;
      if (event.method === 'Network.responseReceived' &&
          p?.response?.url?.includes('/aweme/v1/web/aweme/detail/') &&
          p.response.status === 200) requests.add(p.requestId);
      if (event.method !== 'Network.loadingFinished' || !requests.has(p?.requestId)) continue;
      requests.delete(p.requestId);
      try {
        const response = await page.cdp('Network.getResponseBody', { requestId: p.requestId });
        const data = JSON.parse(response.base64Encoded
          ? Buffer.from(response.body, 'base64').toString('utf8') : response.body);
        const currentURL = await page.url();
        const currentID = currentURL.match(/\/(?:video|note)\/(\d+)/)?.[1];
        if (data.aweme_detail?.video && currentID && data.aweme_detail.aweme_id === currentID) {
          detail = data.aweme_detail;
          break;
        }
      } catch { /* The next completed detail response may be usable. */ }
    }
    if (!detail) await page.waitForTimeout(300);
  }
  if (!detail) throw new Error('未读取到视频。请在打开的浏览器里完成登录或验证，然后回到窗口点击“继续下载”。');
  const maxHeight = config.quality === 'best' ? Infinity : Number(config.quality);
  const formats = (detail.video.bit_rate || []).filter(f =>
    f.format === 'mp4' && f.play_addr?.url_list?.length && f.play_addr.height <= maxHeight
  ).sort((a, b) => b.play_addr.height - a.play_addr.height || b.bit_rate - a.bit_rate);
  const selected = formats[0];
  if (!selected) throw new Error('没有找到所选清晰度的完整视频，请选择“自动最佳”重试。');
  emit('title', { title: detail.desc || '抖音视频' });
  emit('state', { text: `正在下载 ${selected.play_addr.height}p 视频…` });
  let response;
  for (const candidate of selected.play_addr.url_list) {
    const mediaURL = new URL(candidate);
    if (!['https:', 'http:'].includes(mediaURL.protocol)) continue;
    try {
      response = await fetch(candidate, {
        headers: { referer: 'https://www.douyin.com/' }, signal: AbortSignal.timeout(30_000),
      });
      if (response.ok && response.body) break;
      await response.body?.cancel();
      response = null;
    } catch { response = null; }
  }
  if (!response) throw new Error('视频文件暂时无法访问，请稍后重试。');
  const safeTitle = Array.from((detail.desc || '抖音视频').replace(/[<>:"/\\|?*\x00-\x1F]/g, '_')).slice(0, 60).join('').trim();
  const base = `${safeTitle} [${detail.aweme_id}]`;
  part = path.join(config.output, `.${detail.aweme_id}-${Date.now()}.part`);
  const total = Number(response.headers.get('content-length')) || selected.play_addr.data_size || 0;
  let bytes = 0;
  let lastUpdate = 0;
  const begin = Date.now();
  const meter = new Transform({
    transform(chunk, _encoding, callback) {
      bytes += chunk.length;
      const now = Date.now();
      if (now - lastUpdate > 250) {
        const speed = bytes / Math.max((now - begin) / 1000, 0.001);
        emit('progress', { fraction: total ? Math.min(bytes / total, 0.99) : null,
          speed, eta: total ? (total - bytes) / speed : null });
        lastUpdate = now;
      }
      callback(null, chunk);
    },
  });
  await pipeline(Readable.fromWeb(response.body), meter, fs.createWriteStream(part, { flags: 'wx' }));
  if (total && bytes !== total) throw new Error('下载文件不完整，请重试。');
  let finalPath;
  for (let suffix = 0; ; suffix++) {
    finalPath = path.join(config.output, `${base}${suffix ? ` (${suffix})` : ''}.mp4`);
    try { await fsp.link(part, finalPath); break; }
    catch (error) { if (error.code !== 'EEXIST') throw error; }
  }
  await fsp.unlink(part);
  part = undefined;
  if (config.keepSpace) {
    // Keep the space agent-owned so the next douyin item in the queue can
    // take it over and reuse the tab instead of opening a fresh browser task.
    emit('spaceKept', { id: task.spaceId });
  } else {
    await task.finish({ keep: [] });
  }
  completed = true;
  emit('downloaded', { path: finalPath });
} catch (error) {
  if (part) await fsp.unlink(part).catch(() => {});
  const message = String(error.message || error);
  // Leave control failures untouched. Never reclaim or retry an inactive/user-owned space.
  const controlStop = /control|ownership|inactive|unassigned|user.?owned|用户.*控制/i.test(message);
  if (task && !completed && !controlStop) {
    try { await task.handOff(); emit('browserHandoff'); } catch { /* Already handed off. */ }
  }
  emit('error', { text: controlStop ? '浏览器控制已暂停。请处理浏览器提示后点击“继续下载”。' : message });
  process.exitCode = 1;
}
