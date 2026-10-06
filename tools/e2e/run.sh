#!/bin/sh
# End-to-end test of the real WebRTC network: exports the web build, serves it on localhost and plays
# a whole match between three isolated Chrome profiles (mesh, host swap, AI takeover, a rejoin).
# Needs Google Chrome (macOS path in cdp.mjs) and Node 24+. Nothing leaves the machine: no STUN servers
# are used and the page is served from http://127.0.0.1:8061.
#   tools/e2e/run.sh            # export, serve, run full.mjs
#   tools/e2e/run.sh basic      # just two players meeting
set -e
cd "$(dirname "$0")/../.."
tools/export_web.sh > /dev/null
(cd build/web && python3 -m http.server 8061 --bind 127.0.0.1 > /dev/null 2>&1 & echo $! > /tmp/e2e-server.pid)
sleep 1
trap 'kill $(cat /tmp/e2e-server.pid) 2>/dev/null; rm -f /tmp/e2e-server.pid' EXIT
node tools/e2e/${1:-full}.mjs
