class_name MatchSession
extends RefCounted
## One player's side of a match, whatever the network: it keeps the replicated MatchState and keeps
## it equal to everyone else's.
##
## One peer, the host, numbers every change (an *entry*), checks it and sends it to the others; each
## peer applies the entries in order, so all of them hold the same state. The host is simply the
## lowest seat id still reachable: when it leaves, the next one takes over (host swap), asks the others
## how far they got, completes its log from whoever has most, and carries on numbering. A player
## who drops out is replaced by the AI after a grace period (the host plays its moves, as entries like
## any other); the same player can come back with their token and gets the hero back at a safe moment.
## Time only moves through tick(), so tests decide when time passes.
##
## Messages ("m"): hello, entry, entries, submit, reject, refused, redirect, pull, elected, have, ping, bye.

signal changed
## An entry went into the local state (the battle screen plays what it brings).
signal entry_applied(entry: Dictionary)
signal host_changed(new_host: int)
## One of my proposals was refused (the text says why).
signal rejected(reason: String)
## The match can't go on (a desync, the match was full or already started...).
signal halted(reason: String)
signal synced

const PING_INTERVAL := 2.0
const PEER_TIMEOUT := 8.0
const DEFAULT_AI_DELAY := 0.6
const ELECTION_WAIT := 1.0
## Entries that carry the state's fingerprint, so a peer that drifted is noticed at once.
const HASHED: Array[String] = ["act", "go", "start", "lobby"]

var transport: NetTransport
var my_id := 0
var my_name := ""
var my_token := ""
var host_id := 0
var state := MatchState.new()
var is_synced := false
var halt_reason := ""
## Seconds the AI waits before each move it plays (so the others can follow; tests use 0).
var ai_delay := DEFAULT_AI_DELAY

var _now := 0.0
var _ping_timer := 0.0
var _counter := 0
var _pending: Array[Dictionary] = []
var _seen: Dictionary[String, bool] = {}
var _last_heard: Dictionary[int, float] = {}
var _dead: Dictionary[int, bool] = {}
var _absent_since: Dictionary[int, float] = {}
var _turn_unit := -2
var _turn_elapsed := 0.0
var _ai_wait := 0.0
var _electing := false
var _election_deadline := 0.0
var _election_have: Dictionary[int, int] = {}
var _election_pulling := false
var _held: Array = []


## The player who opens the match: seat id = their transport id, host from the start.
static func open_as_host(net: NetTransport, player_name: String, token: String) -> MatchSession:
	var session := MatchSession.new()
	session._setup(net, player_name, token)
	session.host_id = session.my_id
	session.is_synced = true
	session._host_submit(session.my_id, {"k": "join", "id": session.my_id, "name": player_name, "token": token}, true)
	return session


## A player joining through `host_hint`, the peer they are connected to (the host, or any player).
static func open_as_guest(net: NetTransport, player_name: String, token: String, host_hint: int) -> MatchSession:
	var session := MatchSession.new()
	session._setup(net, player_name, token)
	session.host_id = host_hint
	if host_hint in net.reachable_ids():
		session._send_hello()
	return session


func _setup(net: NetTransport, player_name: String, token: String) -> void:
	transport = net
	my_id = net.local_id()
	my_name = player_name
	my_token = token
	net.message_received.connect(_on_message)
	net.peer_connected.connect(_on_peer_connected)
	net.peer_disconnected.connect(_on_peer_lost)


func is_host() -> bool:
	return host_id == my_id


## Whether my hero is the one whose turn it is (and I play it, not the AI).
func is_my_turn() -> bool:
	return state.current_seat() == my_id and not state.seats[my_id].ai


## The hero's unit id for a seat, -1 before the battle.
func unit_of(seat_id: int) -> int:
	return state.unit_of_seat.get(seat_id, -1)


## Whether the local player controls that unit (their own hero while the AI isn't playing it).
func controls_unit(unit_id: int) -> bool:
	var seat_id := state.seat_of_unit(unit_id)
	return seat_id == my_id and state.seats.has(my_id) and not state.seats[my_id].ai


## Peers I can currently reach (not counting those that went quiet).
func peers() -> Array[int]:
	var found: Array[int] = []
	for id in transport.reachable_ids():
		if not _dead.has(id):
			found.append(id)
	return found


# --- My proposals ---------------------------------------------------------------------------

## Asks for a change (the host checks and numbers it). Lobby and battle helpers below build the entries.
func propose(entry: Dictionary) -> void:
	if halted_now():
		return
	_counter += 1
	entry["c"] = "%d-%d" % [my_id, _counter]
	if is_host():
		_host_submit(my_id, entry)
	else:
		_pending.append(entry)
		transport.send(host_id, {"m": "submit", "p": entry})


func set_field(field: String, value: Variant) -> void:
	propose({"k": "set", "id": my_id, "f": field, "v": value})


func configure(setting: String, value: Variant) -> void:
	propose({"k": "cfg", "f": setting, "v": value})


func set_ready(on: bool) -> void:
	propose({"k": "set", "id": my_id, "f": "ready", "v": on})


func start_match() -> void:
	propose({"k": "start"})


func set_placed(on: bool) -> void:
	propose({"k": "ready", "id": my_id, "v": on})


func act(action: BattleActions.Action) -> void:
	propose({"k": "act", "a": ActionCodec.encode(action), "by": my_id})


func back_to_lobby() -> void:
	propose({"k": "lobby"})


## Lets the AI play my hero (to finish the fight without me), or takes it back.
func hand_to_ai(on: bool) -> void:
	propose({"k": "ai", "id": my_id, "v": on})


func halted_now() -> bool:
	return not halt_reason.is_empty()


## Leaves the match: the others see me go.
func leave() -> void:
	transport.broadcast({"m": "bye"})
	transport.close()


# --- Time -----------------------------------------------------------------------------------

func tick(delta: float) -> void:
	_now += delta
	if halted_now():
		return
	_ping_timer += delta
	if _ping_timer >= PING_INTERVAL:
		_ping_timer = 0.0
		transport.broadcast({"m": "ping"})
	for id in peers():
		if _now - _last_heard.get(id, _now) > PEER_TIMEOUT:
			_on_peer_lost(id)
	if _electing:
		_election_tick()
	elif is_host():
		_host_tick(delta)


# --- Receiving ------------------------------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	_dead.erase(id)
	_last_heard[id] = _now
	if id == host_id and not is_host() and not is_synced:
		_send_hello()


func _send_hello() -> void:
	transport.send(host_id, {"m": "hello", "name": my_name, "token": my_token, "have": state.entry_count()})


func _on_message(from: int, message: Dictionary) -> void:
	_last_heard[from] = _now
	_dead.erase(from)
	if halted_now():
		return
	match message.get("m"):
		"hello": _on_hello(from, message)
		"entry": _on_entry(from, message.get("e"))
		"entries": _on_entries(from, message)
		"submit": _on_submit(from, message.get("p"))
		"reject": _on_reject(message)
		"refused": _halt(str(message.get("why", TranslationServer.translate("the match refused you"))))
		"redirect": _on_redirect(message)
		"pull": _on_pull(from, message.get("from"))
		"elected": _on_elected(from, message.get("host"), message.get("have"))
		"have": _on_have(from, message.get("n"))
		"bye": _on_peer_lost(from)


func _on_hello(from: int, message: Dictionary) -> void:
	if not is_host():
		transport.send(from, {"m": "redirect", "host": host_id})
		return
	var token: Variant = message.get("token")
	var have: Variant = message.get("have")
	if token is not String or have is not int:
		return
	var existing := state.seat_for_token(token)
	if existing != null and existing.id != from:
		transport.send(from, {"m": "refused", "why": TranslationServer.translate("that seat belongs to someone else")})
		return
	var error := _host_submit(from, {"k": "join", "id": from, "name": message.get("name", ""), "token": token}, true)
	if not error.is_empty():
		transport.send(from, {"m": "refused", "why": error})
		return
	transport.send(from, {"m": "entries", "list": state.log.slice(clampi(have, 0, state.entry_count()))})


func _on_redirect(message: Dictionary) -> void:
	var new_host: Variant = message.get("host")
	if new_host is int and new_host != host_id and not is_synced:
		host_id = new_host
		_send_hello()


func _on_entries(from: int, message: Dictionary) -> void:
	var list: Variant = message.get("list")
	if list is not Array:
		return
	for entry: Variant in list:
		_on_entry(from, entry)
		if halted_now():
			return
	_election_pulling = false
	if not is_synced:
		is_synced = true
		synced.emit()
		changed.emit()


func _on_entry(from: int, entry: Variant) -> void:
	if entry is not Dictionary or entry.get("n") is not int:
		return
	var number: int = entry["n"]
	if number <= state.entry_count():
		return
	if number > state.entry_count() + 1:
		transport.send(from, {"m": "pull", "from": state.entry_count()})
		return
	var error := state.apply(entry)
	if not error.is_empty():
		_halt(TranslationServer.translate("out of step with the host") + " (%s)" % error)
		return
	if entry.has("h") and entry["h"] != state.fingerprint():
		_halt(TranslationServer.translate("the game state differs from the host's (desync)") + " #%d" % number)
		return
	_after_applied(entry)


func _on_pull(from: int, since: Variant) -> void:
	if since is int:
		transport.send(from, {"m": "entries", "list": state.log.slice(clampi(since, 0, state.entry_count()))})


func _on_reject(message: Dictionary) -> void:
	var nonce := str(message.get("c", ""))
	_pending = _pending.filter(func(p: Dictionary) -> bool: return str(p.get("c")) != nonce)
	rejected.emit(str(message.get("why", "refused")))


func _on_submit(from: int, proposal: Variant) -> void:
	if proposal is not Dictionary:
		return
	if not is_host():
		transport.send(from, {"m": "redirect", "host": host_id})
		return
	_host_submit(from, proposal)


# --- The host: numbering and checking -------------------------------------------------------

## Checks a proposal, numbers it, applies it and sends it on. Returns "" when it went in, else why not.
## `internal`: built by the host itself (a join from a hello), which a proposal can never be.
func _host_submit(from: int, proposal: Dictionary, internal := false) -> String:
	if _electing:
		_held.append([from, proposal])
		return ""
	var nonce := str(proposal.get("c", ""))
	if not nonce.is_empty() and _seen.has(nonce):
		return ""  # Already in the log (a resend after a host swap).
	var error := _authorize(proposal, from, internal)
	var entry: Dictionary = proposal.duplicate()
	if error.is_empty():
		entry["n"] = state.entry_count() + 1
		error = state.apply(entry)
	if not error.is_empty():
		if from == my_id:
			rejected.emit(error)
		elif not nonce.is_empty():
			transport.send(from, {"m": "reject", "c": nonce, "why": error})
		return error
	if entry["k"] in HASHED:
		entry["h"] = state.fingerprint()
	for id in peers():
		transport.send(id, {"m": "entry", "e": entry})
	_after_applied(entry)
	return ""


## Who may ask for what. Joins come from a hello, never from a proposal.
func _authorize(entry: Dictionary, from: int, internal: bool) -> String:
	match entry.get("k"):
		"join":
			return "" if internal else "not allowed"
		"set", "ready":
			return "" if entry.get("id") == from else "not your seat"
		"ai":
			# The host decides, and a player may hand their own hero to the AI, or ask for it back
			# when it isn't their hero's turn.
			if from == host_id:
				return ""
			var asked: Variant = entry.get("id")
			if asked == from and (entry.get("v") == true or state.current_seat() != from):
				return ""
			return "only the host can"
		"cfg", "start", "go", "lobby", "drop":
			return "" if from == host_id else "only the host can"
		"act":
			if entry.get("sys") == true:
				return "" if from == host_id else "only the host can"
			var action := ActionCodec.decode(entry.get("a"))
			if action == null:
				return "malformed action"
			var seat_id := state.seat_of_unit(action.actor_id)
			if seat_id != from or not state.seats.has(from) or state.seats[from].ai:
				return "not your hero"
			return ""
	return "unknown request"


# --- After an entry is applied --------------------------------------------------------------

func _after_applied(entry: Dictionary) -> void:
	var nonce := str(entry.get("c", ""))
	if not nonce.is_empty():
		_seen[nonce] = true
		_pending = _pending.filter(func(p: Dictionary) -> bool: return str(p.get("c")) != nonce)
	var kind: String = entry["k"]
	if kind == "drop" and state.phase == MatchState.Phase.BATTLE:
		_absent_since[int(entry["id"])] = _now
	if kind == "join" or (kind == "ai" and entry.get("v") == false):
		_absent_since.erase(int(entry["id"]))
	if kind == "act" or kind == "go" or kind == "start" or kind == "lobby":
		_ai_wait = 0.0
		_note_turn()
	changed.emit()
	entry_applied.emit(entry)


func _note_turn() -> void:
	var unit := state.battle.state.turn_order.current_unit_id() if state.battle != null and state.battle.state.started else -1
	if unit != _turn_unit:
		_turn_unit = unit
		_turn_elapsed = 0.0


## Seconds left on the current turn (the host's clock; -1 when there is no timer).
func turn_seconds_left() -> float:
	if state.battle == null or not state.battle.state.started or state.battle.state.is_over():
		return -1.0
	return maxf(0.0, float(state.settings["turn"]) - _turn_elapsed)


# --- Losing peers and host swap -------------------------------------------------------------

func _on_peer_lost(id: int) -> void:
	_dead[id] = true
	if id == host_id and not is_host():
		_elect()


func _elect() -> void:
	var candidates: Array[int] = [my_id]
	for id in peers():
		if state.seats.has(id) and state.seats[id].connected:
			candidates.append(id)
	candidates.sort()
	var chosen := candidates[0]
	if chosen == host_id:
		return
	host_id = chosen
	host_changed.emit(chosen)
	if chosen == my_id:
		_electing = true
		_election_have.clear()
		_election_pulling = false
		_election_deadline = _now + ELECTION_WAIT
		for id in peers():
			transport.send(id, {"m": "elected", "host": my_id, "have": state.entry_count()})
	else:
		for proposal in _pending:
			transport.send(host_id, {"m": "submit", "p": proposal})


func _on_elected(from: int, new_host: Variant, have: Variant) -> void:
	if new_host is not int or new_host != from or have is not int:
		return
	if from != host_id:
		host_id = from
		host_changed.emit(from)
	transport.send(from, {"m": "have", "n": state.entry_count()})
	for proposal in _pending:
		transport.send(host_id, {"m": "submit", "p": proposal})


func _on_have(from: int, n: Variant) -> void:
	if _electing and n is int:
		_election_have[from] = n


func _election_tick() -> void:
	var waiting := false
	for id in peers():
		if not _election_have.has(id):
			waiting = true
	if not _election_pulling:
		var best := -1
		var best_count := state.entry_count()
		for id in _election_have:
			if _election_have[id] > best_count:
				best = id
				best_count = _election_have[id]
		if best != -1 and (not waiting or _now >= _election_deadline):
			_election_pulling = true
			_election_deadline = _now + ELECTION_WAIT
			transport.send(best, {"m": "pull", "from": state.entry_count()})
			return
	if (not waiting and not _election_pulling) or _now >= _election_deadline:
		_finish_election()


## The new host has the longest log it could find: bring the others up to it and carry on.
func _finish_election() -> void:
	_electing = false
	_election_pulling = false
	for id in _election_have:
		if _election_have[id] < state.entry_count() and id in peers():
			transport.send(id, {"m": "entries", "list": state.log.slice(_election_have[id])})
	var held := _held
	_held = []
	for item: Array in held:
		_host_submit(item[0], item[1])
	changed.emit()


# --- The host's clock: absent players, the AI, the turn timer -------------------------------

func _host_tick(delta: float) -> void:
	var alive := peers()
	for id in state.seat_ids():
		var seat := state.seats[id]
		if seat.connected and id != my_id and id not in alive:
			_host_submit(my_id, {"k": "drop", "id": id})
	if state.phase != MatchState.Phase.BATTLE or state.battle == null or state.is_over():
		return
	for id in state.seat_ids():
		var seat := state.seats[id]
		if not seat.connected and not seat.ai and _now - _absent_since.get(id, _now) >= float(state.settings["grace"]):
			_host_submit(my_id, {"k": "ai", "id": id, "v": true})
		elif seat.ai and seat.returning and id != state.current_seat():
			_host_submit(my_id, {"k": "ai", "id": id, "v": false})  # Back at a moment that isn't their hero's turn.
	if not state.battle.state.started:
		if state.everyone_placed():
			_host_submit(my_id, {"k": "go"})
		return
	_turn_elapsed += delta
	var current := state.current_seat()
	if current == -1:
		return
	var seat := state.seats[current]
	if seat.ai:
		_ai_wait += delta
		if _ai_wait >= ai_delay:
			_ai_wait = 0.0
			_play_for_ai(current)
	elif _turn_elapsed >= float(state.settings["turn"]):
		var unit_id := state.unit_of_seat[current]
		_host_submit(my_id, {"k": "act", "sys": true, "a": ActionCodec.encode(BattleActions.EndTurn.new(unit_id))})


func _play_for_ai(seat_id: int) -> void:
	var unit_id: int = state.unit_of_seat[seat_id]
	var action := EnemyAI.choose_next(state.battle.state, unit_id)
	var error := _host_submit(my_id, {"k": "act", "sys": true, "a": ActionCodec.encode(action)})
	if not error.is_empty():
		_host_submit(my_id, {"k": "act", "sys": true, "a": ActionCodec.encode(BattleActions.EndTurn.new(unit_id))})


func _halt(reason: String) -> void:
	if halted_now():
		return
	halt_reason = reason
	halted.emit(reason)
