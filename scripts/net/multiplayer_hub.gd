class_name MultiplayerHub
extends Node
## Everything a player needs to be in a match, in one place: the mesh transport, the match session, and the
## two ways in. **Room code** (automatic): a joiner publishes a sealed WebRTC offer in the room on public trackers,
## the host answers it, and the link opens. **Invite link** (manual, always works): the host makes an invite, the
## joiner sends a reply back. Either way the same links, mesh and session follow. It polls the network and
## ticks the session every frame. A returning player gets their seat back with the token the browser kept.

signal session_started
signal invite_ready(code: String, link: String, seat_id: int)
signal reply_ready(code: String, link: String)
signal failed(reason: String)
signal status_changed

const SESSION_FILE := "user://net_session.cfg"
const CODE_VERSION := 1
## At most this many join requests are being answered at once.
const MAX_PENDING_JOINS := 3

var transport: MeshTransport
var session: MatchSession
var factory: LinkFactory = RtcLinkFactory.new()
## The room's secret code on the trackers ("" when there is none: a match made only of invites).
var room_code := ""
var player_name := ""
var token := ""
## Makes the sockets to the trackers (tests give fakes); `use_trackers` false turns the trackers off.
var socket_factory: Callable = func() -> TrackerSocket: return TrackerSocket.Real.new()
var use_trackers := true
var signaling: RoomSignaling

## The manual flow's match name: replies for another match are refused.
var _room_tag := ""
## Seat ids handed out in invites or answers that may not have been used yet.
var _reserved: Dictionary[int, bool] = {}
## A joiner's own offer while it waits for the host's answer through a tracker.
var _wait_link: NetLink
var _wait_offer_id := ""
var _answering := 0


func _process(delta: float) -> void:
	if transport != null:
		transport.poll(delta)
	if session != null:
		session.tick(delta)
		_sync_signaling_role()
	if signaling != null:
		signaling.poll(delta)
	if _wait_link != null:
		_wait_link.poll()


# --- Opening or joining a match -------------------------------------------------------------

## Opens a match as its host (seat 1). Its room code is made now; players can join with it.
func host_room(name_: String) -> void:
	_reset()
	player_name = name_
	token = _random_text(24)
	_room_tag = _random_text(6)
	room_code = RoomCode.generate()
	transport = MeshTransport.new(factory, 1)
	session = MatchSession.open_as_host(transport, name_, token)
	session.halted.connect(failed.emit)
	_store_token()  # So a host who comes back (a reload, a crash) gets seat 1 again.
	_start_signaling()
	session_started.emit()


## Joins with a room code or an invite (the pasted text or link). Returns an error text, or "".
func join(name_: String, text: String) -> String:
	var code := RoomCode.normalize(text)
	if not code.is_empty():
		return join_room(name_, code)
	return join_invite(name_, text)


## Joins by room code: the offer goes into the room on the trackers; the host's answer opens the link. The
## session starts when the answer comes (`session_started`); until then `status()` says what is going on.
func join_room(name_: String, code: String) -> String:
	if not use_trackers:
		return "Joining by room code isn't available here: ask for an invite link instead."
	_reset()
	player_name = name_
	room_code = code
	token = _stored_token(code, -1)
	_start_signaling()
	_wait_offer_id = _random_text(20)
	_wait_link = factory.offer(0, _on_own_offer_ready)
	if _wait_link == null:
		return "WebRTC isn't available here."
	status_changed.emit()
	return ""


func _on_own_offer_ready(blob: String) -> void:
	if signaling == null:
		return
	signaling.publish_offer(_wait_offer_id, NetJson.stringify({"v": CODE_VERSION, "offer": blob, "name": player_name, "token": token}))
	status_changed.emit()


## The host's answer to my offer came through the tracker.
func _on_room_answer(offer_id: String, text: String, _from: String) -> void:
	if offer_id != _wait_offer_id or _wait_link == null:
		return
	var data: Variant = NetJson.parse(text)
	if data is not Dictionary or data.get("v") != CODE_VERSION or data.get("answer") is not String \
			or data.get("for") is not int or data.get("host") is not int:
		return
	var seat: int = data["for"]
	if seat < 1 or seat > 99 or data["host"] < 1 or data["host"] == seat:
		return
	if data.get("token") is String and (data["token"] as String).length() >= 8:
		token = data["token"]  # The host may have given a new one (this browser's old token belongs to a player who is here).
	signaling.retract_offer(_wait_offer_id)
	var link := _wait_link
	_wait_link = null
	transport = MeshTransport.new(factory, seat)
	session = MatchSession.open_as_guest(transport, player_name, token, data["host"])
	session.halted.connect(failed.emit)
	_store_token()
	transport.adopt_offered_link(link, data["host"], seat, data["answer"])
	session_started.emit()


## A joiner's offer reached the host through the tracker: answer it. Anyone but the current host ignores it.
func _on_room_offer(offer_id: String, text: String, from: String) -> void:
	if session == null or not session.is_host() or _answering >= MAX_PENDING_JOINS:
		return
	var data: Variant = NetJson.parse(text)
	if data is not Dictionary or data.get("v") != CODE_VERSION or data.get("offer") is not String or data.get("token") is not String:
		return
	var granted := _seat_for_request(data["token"])
	var seat: int = granted["seat"]
	if seat < 1:
		return  # The match is full or has started and this isn't a player who left.
	_reserved[seat] = true
	_answering += 1
	var host_id := session.my_id
	transport.accept_invite(seat, data["offer"], func(answer_blob: String) -> void:
		_answering = maxi(0, _answering - 1)
		var reply := {"v": CODE_VERSION, "host": host_id, "for": seat, "answer": answer_blob, "key": room_code, "token": granted["token"]}
		if signaling != null:
			signaling.send_answer(from, offer_id, NetJson.stringify(reply)), false)


## The seat a join request gets, and the token its player must use: their own seat if the token is one of a
## player who left; otherwise a new seat (lobby only), with a fresh token when the one sent belongs to
## a player who is here (two tabs of one browser share what the browser remembers).
func _seat_for_request(request_token: String) -> Dictionary:
	var existing := session.state.seat_for_token(request_token)
	if existing != null and not existing.connected:
		return {"seat": existing.id, "token": request_token}
	var granted_token := request_token if existing == null else _random_text(24)
	if session.state.phase != MatchState.Phase.LOBBY or session.state.seats.size() >= MatchState.MAX_PER_SIDE * 2:
		return {"seat": -1, "token": granted_token}
	return {"seat": _free_seat(), "token": granted_token}


## Joins with an invite (the pasted code or link). `reply_ready` then carries what to send back to
## whoever invited. Returns an error text, or "".
func join_invite(name_: String, text: String) -> String:
	var data := InviteCodec.decode(text)
	if data.is_empty() or data.get("v") != CODE_VERSION or data.get("offer") is not String \
			or data.get("room") is not String or data.get("host") is not int or data.get("for") is not int:
		return "That isn't an invite code or link."
	var seat: int = data["for"]
	if seat < 1 or seat > 99 or data["host"] < 1 or data["host"] == seat:
		return "That invite is not valid."
	_reset()
	player_name = name_
	_room_tag = data["room"]
	var key: Variant = data.get("key")
	room_code = key if key is String and RoomCode.is_valid(key) else ""
	token = _stored_token(room_code if not room_code.is_empty() else _room_tag, seat)
	transport = MeshTransport.new(factory, seat)
	session = MatchSession.open_as_guest(transport, name_, token, data["host"])
	session.halted.connect(failed.emit)
	_store_token()
	transport.accept_invite(data["host"], data["offer"], func(blob: String) -> void:
		var reply := {"v": CODE_VERSION, "room": _room_tag, "for": seat, "answer": blob}
		var code := InviteCodec.encode(reply)
		reply_ready.emit(code, InviteCodec.link_for(WebPage.url(), InviteCodec.REPLY_KEY, code)))
	session_started.emit()
	return ""


# --- Inviting by hand -----------------------------------------------------------------------

## Asks for an invite for a new player, or (`for_seat` > 0) for a player coming back to their seat. Any player
## in the match can do it; `invite_ready` carries the code and a link to share.
func create_invite(for_seat := -1) -> void:
	if transport == null or session == null:
		return
	var seat := for_seat if for_seat > 0 else _free_seat()
	_reserved[seat] = true
	var inviter := session.my_id
	transport.create_invite(seat, func(blob: String) -> void:
		var data := {"v": CODE_VERSION, "room": _room_tag, "host": inviter, "for": seat, "offer": blob, "key": room_code}
		var code := InviteCodec.encode(data)
		invite_ready.emit(code, InviteCodec.link_for(WebPage.url(), InviteCodec.JOIN_KEY, code), seat))


## A guest's reply came back (as the pasted code or link): the link can open. Returns an error text, or "".
func accept_reply(text: String) -> String:
	var data := InviteCodec.decode(text)
	if data.is_empty() or data.get("v") != CODE_VERSION or data.get("answer") is not String or data.get("for") is not int:
		return "That isn't a reply code."
	if data.get("room") != _room_tag:
		return "That reply is for another match."
	transport.complete_invite(data["for"], data["answer"])
	return ""


func leave() -> void:
	if session != null:
		session.leave()
	_reset()


func in_match() -> bool:
	return session != null


## What the trackers are doing, for the screen that waits: "" when there is nothing to say.
func status() -> String:
	if signaling == null:
		return ""
	return "%d/%d" % [signaling.connected_count(), signaling.tracker_count()]


# --- The trackers ---------------------------------------------------------------------------

func _start_signaling() -> void:
	if not use_trackers or room_code.is_empty() or signaling != null:
		return
	signaling = RoomSignaling.new(room_code, socket_factory)
	signaling.offer_received.connect(_on_room_offer)
	signaling.answer_received.connect(_on_room_answer)
	signaling.status_changed.connect(status_changed.emit)
	signaling.start()


## The host answers join requests, so it is the one in the swarm; a player who stops being the host (or a
## match without a room code) needs no tracker.
func _sync_signaling_role() -> void:
	if not use_trackers or room_code.is_empty() or _wait_link != null:
		return
	if session.is_host() and signaling == null:
		_start_signaling()
	elif not session.is_host() and signaling != null:
		signaling.close()
		signaling = null


func _reset() -> void:
	if signaling != null:
		signaling.close()
	signaling = null
	transport = null
	session = null
	_wait_link = null
	_wait_offer_id = ""
	_answering = 0
	room_code = ""
	_reserved.clear()


## A seat id nobody has and no pending invite uses.
func _free_seat() -> int:
	var seat := 2
	while session.state.seats.has(seat) or _reserved.has(seat):
		seat += 1
	return seat


## The token this browser kept for this room (the room code, or the manual match's name) and seat (-1: any),
## else a new one.
func _stored_token(room_name: String, seat: int) -> String:
	var file := ConfigFile.new()
	if file.load(SESSION_FILE) == OK and file.get_value("seat", "room", "") == room_name \
			and (seat < 1 or file.get_value("seat", "id", 0) == seat):
		var kept: Variant = file.get_value("seat", "token", "")
		if kept is String and (kept as String).length() >= 8:
			return kept
	return _random_text(24)


func _store_token() -> void:
	if session == null:
		return
	var file := ConfigFile.new()
	file.set_value("seat", "room", room_code if not room_code.is_empty() else _room_tag)
	file.set_value("seat", "id", session.my_id)
	file.set_value("seat", "token", token)
	file.save(SESSION_FILE)


static func _random_text(length: int) -> String:
	var alphabet := "abcdefghjkmnpqrstuvwxyz23456789"
	var bytes := Crypto.new().generate_random_bytes(length)
	var text := ""
	for value in bytes:
		text += alphabet[value % alphabet.length()]
	return text
