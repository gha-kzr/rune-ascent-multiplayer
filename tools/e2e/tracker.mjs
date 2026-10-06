// Two players meet by room code through the real public trackers (one short run: keep it light).
import { launch, Player, sleep } from './cdp.mjs';

const BASE = (process.env.GAME_URL || 'http://127.0.0.1:8061/index.html') + '?e2e=1' + (process.env.E2E_STUN === '1' ? '' : '&stun=0');
const chrome = await launch();
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
try {
  const alice = new Player(chrome.browser, 'alice');
  const bob = new Player(chrome.browser, 'bob');
  await alice.openTab(BASE); await bob.openTab(BASE);
  await Promise.all([alice.waitReady(), bob.waitReady()]);
  await alice.cmd('open'); await bob.cmd('open');
  await alice.cmd('host', 'Alice');
  const a = await alice.until((s) => s.in_match && s.room && s.relays && s.relays.split('/')[0] !== '0', 'alice on a tracker', 30000);
  log('alice hosts room', a.room, 'relays', a.relays);
  const joined = await bob.cmd('join', 'Bob', a.room);
  log('bob asked to join with the code:', JSON.stringify(joined));
  const b = await bob.until((s) => s.in_match && s.synced, 'bob synced through the tracker', 60000);
  log('bob is in: seats', JSON.stringify(b.seats.map((s) => s.name)), 'host', b.host_id);
  const a2 = await alice.until((s) => s.seats.length === 2, 'alice sees bob');
  log('alice sees', JSON.stringify(a2.seats.map((s) => s.name)), 'fingerprints', a2.fingerprint, b.fingerprint);
  log('ALL GOOD');
} catch (e) {
  console.error('FAILED', e.message);
  console.error('console:', chrome.browser.logs.slice(-10));
  process.exitCode = 1;
} finally {
  await chrome.close();
}
