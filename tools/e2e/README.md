# Browser end-to-end tests

The headless tests (`tests/`) cover the match rules and the screens with a fake network; WebRTC itself only
exists in a browser, so these scripts drive real Chrome tabs.

- `cdp.mjs`: a tiny Chrome DevTools driver (isolated browser contexts = separate storage, like separate players).
- `basic.mjs`: two players meet through an invite and a reply.
- `tracker.mjs`: two players meet by room code through the real public trackers (one short run: it talks to
  `tracker.openwebtorrent.com` and `tracker.webtorrent.dev`, so don't loop it).
- `full.mjs`: three players, the mesh, a started match, turns, the host's tab closing (host swap), the AI taking over,
  the host coming back by invite link and getting the hero back.
- The game exposes a small dev-only hook when the page address has `?e2e=1` (`scripts/net/e2e_hook.gd`); `&stun=0`
  keeps the test off the public STUN servers.

Run with `tools/e2e/run.sh` (it exports the web build, serves it on 127.0.0.1:8061 and plays `full`), or
`tools/e2e/run.sh tracker` / `basic`.
