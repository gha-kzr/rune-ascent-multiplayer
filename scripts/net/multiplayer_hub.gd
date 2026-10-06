class_name MultiplayerHub
extends Node
## Everything a player needs to be in a match, in one place: the mesh transport, the match session, and
## the invite flow (host: make an invite, accept the reply; guest: accept an invite, hand out the reply).
## It polls the network and ticks the session every frame. Codes carry a room name so a code for another
## match is refused. A returning player gets their seat back with the token the browser kept.

signal invite_ready(code: String, link: String, seat_id: int)
signal reply_ready(code: String, link: String)
signal failed(reason: String)

const SESSION_FILE := "user://net_session.cfg"
const CODE_VERSION := 1

var transport: MeshTransport
var session: MatchSession
var factory: LinkFactory = RtcLinkFactory.new()
var room := ""
var player_name := ""
var token := ""
## Seat ids handed out in invites that may not have been used yet.
var _reserved: Dictionary[int, bool] = {}


func _process(delta: float) -> void:
	if transport != null:
		transport.poll(delta)
	if session != null:
		session.tick(delta)


## Opens a match as its host (seat 1).
func host_room(name_: String) -> void:
	_reset()
	player_name = name_
	token = _random_text(24)
	room = _random_text(6)
	transport = MeshTransport.new(factory, 1)
	session = MatchSession.open_as_host(transport, name_, token)
	session.halted.connect(failed.emit)
	_store_token()  # So a host who comes back (a reload, a crash) gets seat 1 again.


## Asks for an invite for a new player, or (`for_seat` > 0) for a player coming back to their seat. Any player
## in the match can do it; `invite_ready` carries the code and a link to share.
func create_invite(for_seat := -1) -> void:
	if transport == null or session == null:
		return
	var seat := for_seat if for_seat > 0 else _free_seat()
	_reserved[seat] = true
	var inviter := session.my_id
	transport.create_invite(seat, func(blob: String) -> void:
		var data := {"v": CODE_VERSION, "room": room, "host": inviter, "for": seat, "offer": blob}
		var code := InviteCodec.encode(data)
		invite_ready.emit(code, InviteCodec.link_for(WebPage.url(), InviteCodec.JOIN_KEY, code), seat))


## A guest's reply came back (as the pasted code or link): the link can open. Returns an error text, or "".
func accept_reply(text: String) -> String:
	var data := InviteCodec.decode(text)
	if data.is_empty() or data.get("v") != CODE_VERSION or data.get("answer") is not String or data.get("for") is not int:
		return "That isn't a reply code."
	if data.get("room") != room:
		return "That reply is for another match."
	transport.complete_invite(data["for"], data["answer"])
	return ""


## Joins with an invite (the pasted code or link). `reply_ready` then carries what to send back to
## whoever invited. Returns an error text, or "".
func join(name_: String, text: String) -> String:
	var data := InviteCodec.decode(text)
	if data.is_empty() or data.get("v") != CODE_VERSION or data.get("offer") is not String \
			or data.get("room") is not String or data.get("host") is not int or data.get("for") is not int:
		return "That isn't an invite code or link."
	var seat: int = data["for"]
	if seat < 2 or seat > 99 or data["host"] < 1:
		return "That invite is not valid."
	_reset()
	player_name = name_
	room = data["room"]
	token = _stored_token(room, seat)
	transport = MeshTransport.new(factory, seat)
	session = MatchSession.open_as_guest(transport, name_, token, data["host"])
	session.halted.connect(failed.emit)
	_store_token()
	transport.accept_invite(data["host"], data["offer"], func(blob: String) -> void:
		var reply := {"v": CODE_VERSION, "room": room, "for": seat, "answer": blob}
		var code := InviteCodec.encode(reply)
		reply_ready.emit(code, InviteCodec.link_for(WebPage.url(), InviteCodec.REPLY_KEY, code)))
	return ""


func leave() -> void:
	if session != null:
		session.leave()
	_reset()


func in_match() -> bool:
	return session != null


func _reset() -> void:
	transport = null
	session = null
	_reserved.clear()


## A seat id nobody has and no pending invite uses.
func _free_seat() -> int:
	var seat := 2
	while session.state.seats.has(seat) or _reserved.has(seat):
		seat += 1
	return seat


func _stored_token(room_name: String, seat: int) -> String:
	var file := ConfigFile.new()
	if file.load(SESSION_FILE) == OK and file.get_value("seat", "room", "") == room_name and file.get_value("seat", "id", 0) == seat:
		var kept: Variant = file.get_value("seat", "token", "")
		if kept is String and (kept as String).length() >= 8:
			return kept
	return _random_text(24)


func _store_token() -> void:
	if session == null:
		return
	var file := ConfigFile.new()
	file.set_value("seat", "room", room)
	file.set_value("seat", "id", session.my_id)
	file.set_value("seat", "token", token)
	file.save(SESSION_FILE)


static func _random_text(length: int) -> String:
	var alphabet := "abcdefghjkmnpqrstuvwxyz23456789"
	var crypto := Crypto.new()
	var bytes := crypto.generate_random_bytes(length)
	var text := ""
	for value in bytes:
		text += alphabet[value % alphabet.length()]
	return text
