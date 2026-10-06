// A tiny Chrome DevTools driver (Node 24 has fetch and WebSocket built in).
import { spawn } from 'node:child_process';

export const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function launch(port = 9333, profile = '/tmp/e2e-chrome-profile') {
  const proc = spawn(CHROME, [
    '--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
    '--disable-features=WebRtcHideLocalIpsWithMdns', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
    '--ignore-gpu-blocklist', '--autoplay-policy=no-user-gesture-required', '--window-size=1280,720',
    '--no-first-run', '--no-default-browser-check', 'about:blank',
  ], { stdio: 'ignore' });
  for (let i = 0; i < 60; i++) {
    try { const r = await fetch(`http://127.0.0.1:${port}/json/version`); if (r.ok) break; } catch {}
    await sleep(250);
  }
  const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
  const browser = new Session(version.webSocketDebuggerUrl);
  await browser.open();
  return { proc, browser, port, close: async () => { try { await browser.send('Browser.close'); } catch {} proc.kill(); } };
}

export class Session {
  constructor(url) { this.url = url; this.id = 0; this.pending = new Map(); this.logs = []; }
  open() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(this.url);
      this.ws.onopen = () => resolve();
      this.ws.onerror = (e) => reject(e);
      this.ws.onmessage = (m) => {
        const msg = JSON.parse(m.data);
        if (msg.id && this.pending.has(msg.id)) {
          const { resolve, reject } = this.pending.get(msg.id);
          this.pending.delete(msg.id);
          msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
        } else if (msg.method === 'Runtime.consoleAPICalled') {
          this.logs.push(msg.params.args.map((a) => a.value ?? a.description).join(' '));
        } else if (msg.method === 'Runtime.exceptionThrown') {
          this.logs.push('EXCEPTION ' + JSON.stringify(msg.params.exceptionDetails.text));
        }
      };
    });
  }
  send(method, params = {}, sessionId) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params, sessionId }));
    });
  }
  close() { this.ws.close(); }
}

// One player: an isolated browser context (own storage) with a tab.
export class Player {
  constructor(browser, name) { this.browser = browser; this.name = name; this.cmdId = 0; }
  async openTab(url) {
    if (!this.contextId) this.contextId = (await this.browser.send('Target.createBrowserContext')).browserContextId;
    const { targetId } = await this.browser.send('Target.createTarget', { url, browserContextId: this.contextId });
    this.targetId = targetId;
    const { sessionId } = await this.browser.send('Target.attachToTarget', { targetId, flatten: true });
    this.sessionId = sessionId;
    await this.browser.send('Runtime.enable', {}, sessionId);
    await this.browser.send('Page.enable', {}, sessionId);
    this.alive = true;
  }
  async closeTab() { await this.browser.send('Target.closeTarget', { targetId: this.targetId }); this.alive = false; }
  async eval(expression) {
    const r = await this.browser.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, this.sessionId);
    if (r.exceptionDetails) throw new Error(`${this.name}: ${JSON.stringify(r.exceptionDetails)}`);
    return r.result.value;
  }
  async waitReady(timeoutMs = 120000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      try { if (await this.eval('window.e2e_ready === true')) return; } catch {}
      await sleep(500);
    }
    throw new Error(`${this.name}: the game never became ready`);
  }
  // Runs a command in the game and returns its answer.
  async cmd(name, ...args) {
    const id = ++this.cmdId;
    await this.eval(`window.e2e_cmd(${JSON.stringify(JSON.stringify({ id, name, args }))})`);
    for (let i = 0; i < 100; i++) {
      const out = await this.eval(`JSON.stringify(window.e2e_out[${id}] ?? null)`);
      if (out && out !== 'null') return JSON.parse(out);
      await sleep(100);
    }
    throw new Error(`${this.name}: no answer to ${name}`);
  }
  async out(key, timeoutMs = 30000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const v = await this.eval(`JSON.stringify(window.e2e_out.${key} ?? null)`);
      if (v && v !== 'null') return JSON.parse(v);
      await sleep(250);
    }
    throw new Error(`${this.name}: ${key} never appeared`);
  }
  async status() { return this.cmd('status'); }
  async until(predicate, what, timeoutMs = 30000) {
    const start = Date.now();
    let last;
    while (Date.now() - start < timeoutMs) {
      last = await this.status();
      if (predicate(last)) return last;
      await sleep(300);
    }
    throw new Error(`${this.name}: timed out waiting for ${what}; last status ${JSON.stringify(last)}`);
  }
}
