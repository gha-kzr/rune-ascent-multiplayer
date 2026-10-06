class_name E2eHook
extends Node
## Dev-only: lets a script drive the game from the browser's JavaScript, for end-to-end tests of the real
## WebRTC network in two tabs (`?e2e=1` in the page address turns it on; `&stun=0` keeps the test off the public
## STUN servers). JS calls `window.e2e_cmd(JSON.stringify({id, name, args}))`; the answer appears in
## `window.e2e_out[id]`, and the invite / reply codes in `window.e2e_out.invite` / `.reply`.

var game: Game
var _callback: JavaScriptObject
var _wired: MultiplayerHub


func _ready() -> void:
	if not WebPage.is_web():
		return
	var window := JavaScriptBridge.get_interface("window")
	_callback = JavaScriptBridge.create_callback(_on_command)
	window.e2e_cmd = _callback
	JavaScriptBridge.eval("window.e2e_out = {}; window.e2e_ready = true;", true)
	if WebPage.query("stun") == "0":
		RtcLink.use_stun = false


func _flow() -> NetFlow:
	return game.screen as NetFlow


func _hub() -> MultiplayerHub:
	return _flow().hub if _flow() != null else null


func _on_command(args: Array) -> void:
	var request: Variant = JSON.parse_string(str(args[0]))
	if request is not Dictionary:
		return
	var result: Variant = _run(str(request.get("name")), request.get("args", []))
	JavaScriptBridge.eval("window.e2e_out[%d] = %s;" % [int(request.get("id", 0)), JSON.stringify(result)], true)


func _run(command: String, args: Array) -> Variant:
	match command:
		"open":
			game.show_multiplayer()  # An invite in the page's address joins from here.
			_listen()
			return true
		"host":
			_flow()._on_host(str(args[0]))
			_listen()
			return true
		"invite":
			_hub().create_invite(int(args[0]) if args.size() > 0 else -1)
			return true
		"join":
			var flow := _flow()
			flow._on_join(str(args[0]), str(args[1]))
			_listen()
			return _hub().session != null
		"reply":
			return _hub().accept_reply(str(args[0]))
		"status":
			return _status()
		"set":
			_hub().session.set_field(str(args[0]), args[1])
		"cfg":
			_hub().session.configure(str(args[0]), args[1])
		"ready":
			_hub().session.set_ready(bool(args[0]))
		"start":
			_hub().session.start_match()
		"placed":
			_hub().session.set_placed(true)
		"end_turn":
			var session := _hub().session
			if session.is_my_turn():
				session.act(BattleActions.EndTurn.new(session.unit_of(session.my_id)))
				return true
			return false
		"ai":
			_hub().session.hand_to_ai(bool(args[0]))
		"lobby":
			_hub().session.back_to_lobby()
		"leave":
			_flow()._leave()
	return true


## Hands the invite and reply codes to JS when they are ready.
func _listen() -> void:
	var hub := _hub()
	if hub == null or hub == _wired:
		return
	_wired = hub
	hub.invite_ready.connect(func(code: String, link: String, seat: int) -> void:
		JavaScriptBridge.eval("window.e2e_out.invite = %s;" % JSON.stringify({"code": code, "link": link, "seat": seat}), true))
	hub.reply_ready.connect(func(code: String, link: String) -> void:
		JavaScriptBridge.eval("window.e2e_out.reply = %s;" % JSON.stringify({"code": code, "link": link}), true))
	hub.failed.connect(func(reason: String) -> void:
		JavaScriptBridge.eval("window.e2e_out.failed = %s;" % JSON.stringify(reason), true))


func _status() -> Dictionary:
	var hub := _hub()
	if hub == null or hub.session == null:
		return {"in_match": false, "room": hub.room_code if hub != null else "", "relays": hub.status() if hub != null else "",
				"screen": game.screen.get_class() if game.screen != null else ""}
	var session := hub.session
	var seats := []
	for id in session.state.seat_ids():
		var seat := session.state.seats[id]
		seats.append({"id": id, "name": seat.name, "connected": seat.connected, "ai": seat.ai, "side": seat.side, "hero": seat.hero, "ready": seat.ready})
	return {"in_match": true, "room": hub.room_code, "relays": hub.status(), "my_id": session.my_id, "host_id": session.host_id, "synced": session.is_synced, "halted": session.halt_reason,
			"phase": session.state.phase, "entries": session.state.entry_count(), "fingerprint": session.state.fingerprint(),
			"peers": session.peers(), "direct": hub.transport.direct_ids(), "seats": seats, "my_turn": session.is_my_turn(),
			"started": session.state.battle != null and session.state.battle.state.started,
			"over": session.state.is_over(), "screen": game.screen.get_class() if game.screen != null else "",
			"current_seat": session.state.current_seat()}
