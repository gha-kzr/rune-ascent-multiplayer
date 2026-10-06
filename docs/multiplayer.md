# Multiplayer (PvP) — how it works

A fight between human players, up to 4 against 4, one hero each, from a static web page. Everything the page needs
to work without a server is in `scripts/net/` (rules, session, network) and `scripts/game/net/` (screens).

## The idea: everyone replays the same log

The battle rules are deterministic (a seeded random generator, no clock), so players do not send each other game
states, only *what was decided*:

- The match is a **log of entries**: a player joined, a hero was picked, the host chose the map, the match started,
  a hero was placed, a hero moved or cast, a turn ended, the AI took over a hero...
- One peer, the **host**, numbers each entry, checks it (is it your hero, is it your turn, is it legal) and sends it
  to everyone. Every peer applies the entries in order with the same rules, so everyone holds the same battle.
- Each entry that changes the battle carries a **fingerprint** of the state after it; a peer whose state differs stops
  with a clear "desync" message instead of playing on a wrong board.
- The screen of each player keeps its own copy of the battle and animates what the log brings; a click only becomes a
  *proposal* to the host, and nothing changes on screen until the host's entry comes back.

Code: `MatchState` (the replicated state and every entry kind), `MatchSession` (numbering, checking, host swap,
timers, AI, reconnect), `ActionCodec` and `StateHash`, `NetBattleController` (the fight screen).

## Host swap

The host is the lowest seat id still reachable. When it disappears, each peer computes the new host the same way; the
new host asks the others how far their logs go, completes its own from whoever has most (an entry the old host sent to
only some of them is not lost), brings the others up to date, and carries on numbering. Proposals that were in flight
are sent again to the new host (each carries a nonce, so none is applied twice).

## A player who leaves: the AI, and coming back

After the grace time (host setting, 20 s by default) the host puts an entry in the log that gives the player's hero to
the AI; from then on the host plays that hero's turns (the AI's moves are entries too, so every peer sees the same).
The players panel tags "(AI)" and "(away)". A player can also hand their own hero to the AI, or ask for it back.

A player who comes back opens the room again with the same browser: a token kept in the browser (and sent sealed) gets
their seat back. They replay the log, then the host returns the hero at a moment that is not its turn.

## Connecting without a server

WebRTC data channels connect players directly; the only thing missing is a way to pass the first messages (an *offer*
and an *answer*) between two browsers. Two ways, the same links behind them:

1. **Room code (automatic).** The host's room is a code of 12 characters. A joiner puts a WebRTC offer, **sealed with a
   key made from the code**, into that room on public WebTorrent trackers (`tracker.openwebtorrent.com`,
   `tracker.webtorrent.dev`, both at once); the host is in the same room, answers it the same way, and the link opens.
   The trackers carry a few kilobytes and never see anything readable.
2. **Invite link (manual, always works).** The host makes an invite (a link or code), sends it by any means, the
   joiner opens it and gets a reply to send back; the host pastes it. No third party at all.

After the first link to a newcomer, the rest of the **mesh** builds itself: the newcomer asks each player its first
contact knows for a link, the setup messages passing through that contact. Two players that cannot link directly still
talk through a player both can reach.

### What the public trackers can and cannot see

- The room is named on the tracker by a hash of the code; the code itself never leaves the players.
- Offers and answers (with the addresses in them) are sealed with AES-256-CBC and an HMAC-SHA256 (keys from
  PBKDF2-HMAC-SHA256 of the code); a message that was altered, or sealed with another code, is dropped. Anyone who does
  not know the code can neither read the setup messages nor produce valid ones.
- The code is about 59 bits: share it like a password. Anyone who has it can join the lobby (the host can see who is in).
- WebRTC itself is encrypted (DTLS), and players see each other's IP addresses (inherent to WebRTC).
- Public STUN servers (Google, Cloudflare) help two players behind home routers find each other. There is no relay (TURN):
  a few strict networks will not connect directly; the mesh then relays through a player that reaches both, and the
  invite link is the fallback.
- Reliability: two trackers are used at once, a tracker that drops is retried with a growing pause (no hammering), and the
  trackers are only needed to *connect* (and to let someone back in): a fight in progress does not depend on them.
  They are community services with no guarantee; if both are down, use invite links.

## Fairness and rules

- Heroes: the roster's three heroes at level 30 with the default five-spell loadout, no runes; their level is never shown.
- Maps: the same shapes as the tower's (open field, mountain, crater, islands, canyon, ruins), made *symmetric under a
  half turn* with a 3 x 3 start zone for each side (`PvpMap`), so neither side is favoured; the map is drawn again on every
  peer from three numbers (shape, size, seed), and the lobby previews it with the QA map preview.
- Turns: initiative order over all heroes; a turn timer (host setting, 30 s by default) ends an idle player's turn.
- Sudden death from round 40 (every hero loses 10 % of max HP at its turn start) so a stalled fight always ends.

## Hosting

The game is a static web export (`tools/export_web.sh`); `tools/export_web.sh --publish` commits it to the local
`gh-pages` branch, `git push origin gh-pages` publishes it, and Settings → Pages → `gh-pages` / root serves it. Saves
and settings live in the browser, separate from the original game's.

## Tests

- `tests/test_pvp_basics.gd`, `test_match_session.gd` (lobby, start, placement, turns, timer, host swap with a partly
  delivered log, AI takeover, rejoin, desync), `test_net_battle.gd`, `test_net_screens.gd`: the logic on a fake network.
- `test_mesh_transport.gd`, `test_room_signaling.gd`, `test_room_join.gd`, `test_room_crypto.gd`, `test_invite_codec.gd`:
  the connection layers with fake links and fake trackers.
- `tools/e2e/`: real Chrome tabs and real WebRTC (and, for `tracker.mjs`, the real public trackers). See its README.

## Known limits

- Up to 8 players (4 per side); no spectators; no chat.
- A match needs a human host in a visible tab (browsers slow down background tabs); if the host leaves, another player takes over.
- Without TURN some networks cannot connect (use another player as host, or an invite from someone who can reach both).
- If every human leaves, the match is over: the log only lives in the players' browsers.
