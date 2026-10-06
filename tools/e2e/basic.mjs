import { launch, Player, sleep } from './cdp.mjs';

const URL = '' + (process.env.GAME_URL || 'http://127.0.0.1:8061/index.html') + '?e2e=1' + (process.env.E2E_STUN === '1' ? '' : '&stun=0');
const chrome = await launch();
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
try {
  const alice = new Player(chrome.browser, 'alice');
  const bob = new Player(chrome.browser, 'bob');
  await alice.openTab(URL); await bob.openTab(URL);
  await Promise.all([alice.waitReady(), bob.waitReady()]);
  log('both games are up');
  await alice.cmd('open'); await bob.cmd('open');
  await alice.cmd('host', 'Alice');
  log('alice hosts');
  await alice.cmd('invite');
  const invite = await alice.out('invite', 40000);
  log('invite ready, code length', invite.code.length, 'link length', invite.link.length);
  const joined = await bob.cmd('join', 'Bob', invite.link);
  log('bob joins:', joined);
  const reply = await bob.out('reply', 40000);
  log('reply ready, length', reply.code.length);
  log('alice accepts reply:', JSON.stringify(await alice.cmd('reply', reply.link)));
  const a = await alice.until((s) => s.seats && s.seats.length === 2 && s.peers.length === 1, 'two seats on alice');
  const b = await bob.until((s) => s.synced && s.seats.length === 2, 'bob synced');
  log('alice sees', JSON.stringify(a.seats.map((s) => s.name)), 'bob sees', JSON.stringify(b.seats.map((s) => s.name)), 'host', b.host_id, 'screens', a.screen, b.screen);
  await sleep(1500);
  log('alice fingerprint', (await alice.status()).fingerprint, 'bob', (await bob.status()).fingerprint);
  log('console (alice):', alice.browser.logs.slice(-6));
} catch (e) {
  console.error('FAILED', e.message);
  console.error('console:', chrome.browser.logs.slice(-15));
  process.exitCode = 1;
} finally {
  await chrome.close();
}
