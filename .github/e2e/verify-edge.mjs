import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const [, , edge, screenshot, filename, body] = process.argv;
assert(edge && screenshot && filename && body, 'usage: verify-edge.mjs EDGE SCREENSHOT FILE TEXT');
assert.equal(process.platform, 'win32', 'Run this browser check on native Windows');
const profile = await mkdtemp(path.join(os.tmpdir(), 'server-files-edge-'));
const browser = spawn(edge, [
  '--headless=new', '--no-first-run', '--no-default-browser-check', '--disable-gpu',
  '--disable-sync', '--disable-background-networking', '--remote-debugging-port=0',
  `--user-data-dir=${profile}`, 'about:blank',
], { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
const exited = once(browser, 'exit');
let browserError;
browser.on('error', error => { browserError = error; });
let stderr = '';
browser.stderr.on('data', bytes => { stderr = (stderr + bytes).slice(-3000); });
let socket;
const pending = new Map();
try {
  let port;
  for (let attempt = 0; attempt < 120; attempt++) {
    if (browserError) throw browserError;
    if (browser.exitCode !== null) throw new Error(`Edge exited early (${browser.exitCode}): ${stderr}`);
    try {
      port = Number((await readFile(path.join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]);
      if (port > 0) break;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    await delay(200);
  }
  assert(port > 0, `Edge DevTools did not start: ${stderr}`);
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`, {signal: AbortSignal.timeout(5000)})).json();
  const page = targets.find(target => target.type === 'page');
  assert(page?.webSocketDebuggerUrl, 'No Edge page target');
  socket = new WebSocket(page.webSocketDebuggerUrl);
  await Promise.race([
    new Promise((resolve, reject) => {
      socket.addEventListener('open', resolve, {once: true});
      socket.addEventListener('error', reject, {once: true});
    }),
    delay(5000, null, {ref: false}).then(() => { throw new Error('Edge DevTools WebSocket timeout'); }),
  ]);
  socket.addEventListener('message', event => {
    const data = JSON.parse(event.data);
    const message = pending.get(data.id);
    if (!message) return;
    pending.delete(data.id);
    if (data.error) message.reject(new Error(data.error.message));
    else message.resolve(data.result);
  });
  let sequence = 0;
  function send(method, params = {}) {
    const id = ++sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`Edge command timed out: ${method}`));
      }, 12000);
      pending.set(id, {
        resolve: value => { clearTimeout(timer); resolve(value); },
        reject: error => { clearTimeout(timer); reject(error); },
      });
      socket.send(JSON.stringify({id, method, params}));
    });
  }
  async function evaluate(expression) {
    const result = await send('Runtime.evaluate', {expression, returnByValue: true});
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text);
    return result.result.value;
  }
  async function waitFor(expression, description) {
    for (let attempt = 0; attempt < 80; attempt++) {
      if (await evaluate(expression)) return;
      await delay(200);
    }
    throw new Error(`Edge did not show ${description}`);
  }

  async function dragResize(dialogId, handleId) {
    const before = await evaluate(`(() => {
      const box = document.getElementById(${JSON.stringify(dialogId)}).getBoundingClientRect();
      const handle = document.getElementById(${JSON.stringify(handleId)}).getBoundingClientRect();
      return {width: box.width, height: box.height, x: handle.x + handle.width / 2, y: handle.y + handle.height / 2};
    })()`);
    await send('Input.dispatchMouseEvent', {type: 'mousePressed', x: before.x, y: before.y, button: 'left', buttons: 1, clickCount: 1});
    await send('Input.dispatchMouseEvent', {type: 'mouseMoved', x: before.x + 29, y: before.y + 25, button: 'left', buttons: 1});
    await send('Input.dispatchMouseEvent', {type: 'mouseReleased', x: before.x + 29, y: before.y + 25, button: 'left', clickCount: 1});
    await waitFor(`(() => {
      const dialog = document.getElementById(${JSON.stringify(dialogId)});
      const box = dialog.getBoundingClientRect();
      return dialog.hasAttribute('data-resized') && box.width > ${before.width + 16} && box.height > ${before.height + 16};
    })()`, `${dialogId} resized by pointer`);
  }

  const tokens = 'span.syntax-property, span.syntax-string, span.syntax-number, span.syntax-literal';
  function hasJsonColors(selector) {
    return `(() => {
      const nodes = [...document.querySelectorAll(${JSON.stringify(selector + ' :is(' + tokens + ')')})];
      return nodes.some(n => n.textContent === '"theme"') && nodes.some(n => n.textContent === '128') &&
        nodes.some(n => n.textContent === 'true') && new Set(nodes.map(n => getComputedStyle(n).color)).size === 4;
    })()`;
  }

  await send('Emulation.setEmulatedMedia', {features: [{name: 'prefers-reduced-motion', value: 'reduce'}]});
  await send('Emulation.setDeviceMetricsOverride', {width: 1280, height: 800, deviceScaleFactor: 1, mobile: false});
  const url = 'http://127.0.0.1:8878/';
  const navigation = await send('Page.navigate', {url});
  assert(!navigation.errorText, navigation.errorText);
  const file = `[data-search-path="${filename}"]`;
  const preview = `${file} [data-preview-kind="text"]`;
  await waitFor(`location.href === ${JSON.stringify(url)} && Boolean(document.querySelector(${JSON.stringify(preview)}))`, filename);
  await evaluate(`document.querySelector(${JSON.stringify(preview)}).click()`);
  await waitFor(`document.querySelector('#file-preview[open] #preview-content pre')?.textContent.trim() === ${JSON.stringify(body)}`, 'the expected SSH file contents');
  await evaluate(`document.querySelector('#preview-close').click()`);
  await waitFor(`!document.querySelector('#file-preview[open]')`, 'the text preview closed');
  await waitFor(`Boolean(document.querySelector('[data-server-storage]') && document.querySelector('.folder-breadcrumb'))`, 'storage and folder breadcrumbs');
  const configRow = '[data-search-path="config.json"]';
  await evaluate(`document.querySelector('${configRow} .item .icon').click()`);
  await waitFor(hasJsonColors('#file-preview[open] #preview-content'), 'four JSON syntax colors in preview');
  await dragResize('file-preview', 'preview-resize');
  await waitFor(`[...document.querySelectorAll('#recent-files button')].some(button => button.textContent.includes('config.json'))`, 'JSON in Recently Opened');
  const { product } = await send('Browser.getVersion');
  const shot = await send('Page.captureScreenshot', {format: 'png'});
  await writeFile(screenshot, Buffer.from(shot.data, 'base64'));
  await evaluate(`document.querySelector('#preview-close').click()`);
  await evaluate(`document.querySelector('${configRow} [data-edit-url]').click()`);
  await waitFor(hasJsonColors('#file-editor[open] #editor-code'), 'four JSON syntax colors in editor');
  await dragResize('file-editor', 'editor-resize');
  console.log(`${product} rendered the server file list, verified ${filename}, and checked JSON syntax colors and pointer resizing in preview and editor.`);
} finally {
  socket?.close();
  browser.kill();
  await Promise.race([exited.catch(() => {}), delay(3000)]);
  await rm(profile, {recursive: true, force: true}).catch(() => {});
}
