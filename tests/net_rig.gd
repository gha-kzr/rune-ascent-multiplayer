class_name NetRig
extends RefCounted
## Test helper: players on a MemoryNetwork, all linked to each other, with a clock the test turns.

var net := MemoryNetwork.new()
var sessions: Dictionary[int, MatchSession] = {}


static func token_of(id: int) -> String:
	return "token-for-seat-%d" % id


func host(id := 1, player_name := "Host") -> MatchSession:
	sessions[id] = MatchSession.open_as_host(net.transport(id), player_name, token_of(id))
	return sessions[id]


## A player who links to everyone already there and joins through `via` (the host by default).
func guest(id: int, player_name := "", via := 1) -> MatchSession:
	for other in sessions.keys():
		net.connect_peers(id, other)
	sessions[id] = MatchSession.open_as_guest(net.transport(id), player_name if not player_name.is_empty() else "Guest %d" % id, token_of(id), via)
	net.flush()
	return sessions[id]


## `seconds` of game time, in small steps, delivering messages between them.
func run(seconds: float, step := 0.1) -> void:
	var elapsed := 0.0
	net.flush()
	while elapsed < seconds - 0.00001:
		for id in sessions.keys():
			sessions[id].tick(step)
		net.flush()
		elapsed += step


## The same fingerprint and entry count on every session still in the match.
func in_step() -> bool:
	var fingerprint := -1
	var count := -1
	for id in sessions:
		if net.transport(id).closed or sessions[id].halted_now():
			continue
		var mine := sessions[id].state.fingerprint()
		var entries := sessions[id].state.entry_count()
		if fingerprint == -1:
			fingerprint = mine
			count = entries
		elif mine != fingerprint or entries != count:
			return false
	return true


## Everyone ready and the match started, with `a_count` players on side A and the rest on side B (ids 1..n).
func start_match(total: int, a_count: int) -> void:
	for id in range(1, total + 1):
		if id == 1:
			host(1, "Host")
		else:
			guest(id)
	for id in range(1, total + 1):
		sessions[id].set_field("side", 0 if id <= a_count else 1)
		sessions[id].set_field("hero", (id - 1) % PvpHeroes.hero_count())
	net.flush()
	for id in range(1, total + 1):
		sessions[id].set_ready(true)
	net.flush()
	sessions[1].start_match()
	net.flush()
