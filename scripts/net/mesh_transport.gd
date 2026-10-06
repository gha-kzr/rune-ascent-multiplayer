class_name MeshTransport
extends NetTransport
## A full mesh of direct links between players, built from the links a LinkFactory makes. The first
## link to a newcomer comes from an invite; the rest of the mesh follows by itself: the newcomer asks
## each player its first contact knows about for a link, and the setup messages (offers, answers) travel
## through that contact. Messages to a player there is no direct link to go through a player both can
## reach, so a pair that can't connect still talks. Everything on the wire is JSON text:
##   {t:"g", f, b}            a game message from f
##   {t:"fwd", to, f, b}      a game message for `to`, passing through
##   {t:"links", ids}         the direct peers of the sender (what they can reach for me)
##   {t:"rtc", to, f, k, blob}  link setup (offer / answer) for `to`, passing through
##   {t:"part", id, i, of, d}   a long message in pieces
## Reachable = direct links plus what each direct peer says it is linked to.

const MAX_PIECE := 12000
const LINK_TIMEOUT := 20.0

var factory: LinkFactory
var _id := 0
var _links: Dictionary[int, NetLink] = {}
## Per direct peer: the peers it says it is linked to.
var _peer_links: Dictionary[int, Array] = {}
var _reachable: Array[int] = []
## Links being built through the mesh, by remote id: [link, started_at].
var _building: Dictionary[int, Array] = {}
## Links made for invites, waiting for their answer (by remote id).
var _invited: Dictionary[int, NetLink] = {}
var _clock := 0.0
var _piece_counter := 0
var _pieces: Dictionary[String, Dictionary] = {}
var _closed := false
## Whether this player connected through an invite: it then builds the rest of the mesh.
var joins_the_mesh := false


func _init(link_factory: LinkFactory, local_player_id: int) -> void:
	factory = link_factory
	_id = local_player_id


func local_id() -> int:
	return _id


func reachable_ids() -> Array[int]:
	return _reachable.duplicate()


## The peers with a direct link open.
func direct_ids() -> Array[int]:
	var ids: Array[int] = []
	for id in _links:
		if _links[id].is_open:
			ids.append(id)
	ids.sort()
	return ids


# --- Invites (the first link to a newcomer) --------------------------------------------------

## Makes a link for the player that will be `remote_id`; `on_ready(offer_blob)` gets what to hand over.
func create_invite(remote_id: int, on_ready: Callable) -> void:
	var link := factory.offer(remote_id, on_ready)
	if link == null:
		return
	_watch(link, remote_id)
	_invited[remote_id] = link


## The answer of an invited player arrived: the link can finish.
func complete_invite(remote_id: int, answer_blob: String) -> void:
	var link: NetLink = _invited.get(remote_id)
	if link != null:
		factory.complete(link, answer_blob)


## Accepts an offer from `remote_id`; `on_ready(answer_blob)` gets what to send back. A newcomer (the default)
## then builds the rest of the mesh; a player who already is in the match (answering a joiner) doesn't.
func accept_invite(remote_id: int, offer_blob: String, on_ready: Callable, newcomer := true) -> void:
	joins_the_mesh = joins_the_mesh or newcomer
	var link := factory.answer(remote_id, offer_blob, on_ready)
	if link != null:
		_watch(link, remote_id)
		_building[remote_id] = [link, _clock]  # Polled (its answer is made while polling) until it opens.


## A link this player offered before it knew its seat (joining through a tracker): now the host has
## answered, so the player has its seat id and the link has its remote end.
func adopt_offered_link(link: NetLink, remote_id: int, local_player_id: int, answer_blob: String) -> void:
	_id = local_player_id
	joins_the_mesh = true
	_watch(link, remote_id)
	_building[remote_id] = [link, _clock]
	factory.complete(link, answer_blob)


# --- Sending --------------------------------------------------------------------------------

func send(to_id: int, message: Dictionary) -> void:
	if _closed or to_id == _id:
		return
	var body := NetJson.stringify(message)
	var link: NetLink = _links.get(to_id)
	if link != null and link.is_open:
		_send_text(link, {"t": "g", "f": _id, "b": message}, body)
		return
	var via := _relay_for(to_id)
	if via != -1:
		_send_text(_links[via], {"t": "fwd", "to": to_id, "f": _id, "b": message}, body)


func close() -> void:
	_closed = true
	for id in _links.keys():
		_links[id].close()
	_links.clear()
	_peer_links.clear()
	_set_reachable([])


func poll(delta := 0.0) -> void:
	_clock += delta
	for id in _links.keys():
		_links[id].poll()
	for id in _invited.keys():
		_invited[id].poll()
	for id in _building.keys():
		var entry: Array = _building[id]
		(entry[0] as NetLink).poll()
		if _clock - float(entry[1]) > LINK_TIMEOUT and not (entry[0] as NetLink).is_open:
			(entry[0] as NetLink).close()
			_building.erase(id)


# --- Links ----------------------------------------------------------------------------------

func _watch(link: NetLink, remote_id: int) -> void:
	link.remote_id = remote_id
	link.opened.connect(_on_opened.bind(link))
	link.closed.connect(_on_closed.bind(link))
	link.text_received.connect(_on_text.bind(link))


func _on_opened(link: NetLink) -> void:
	var existing: NetLink = _links.get(link.remote_id)
	if existing != null and existing != link:
		existing.close()
	_links[link.remote_id] = link
	_invited.erase(link.remote_id)
	_building.erase(link.remote_id)
	_send_links(link)
	_announce_links(link.remote_id)
	_recompute()


func _on_closed(link: NetLink) -> void:
	if _links.get(link.remote_id) == link:
		_links.erase(link.remote_id)
		_peer_links.erase(link.remote_id)
		_announce_links(-1)
		_recompute()
	if _invited.get(link.remote_id) == link:
		_invited.erase(link.remote_id)
	if _building.has(link.remote_id) and _building[link.remote_id][0] == link:
		_building.erase(link.remote_id)


func _send_links(link: NetLink) -> void:
	var body := {"t": "links", "ids": direct_ids()}
	link.send_text(NetJson.stringify(body))


## Tells every direct peer (but `except`) what I am linked to now.
func _announce_links(except: int) -> void:
	for id in direct_ids():
		if id != except:
			_send_links(_links[id])


func _recompute() -> void:
	var now: Array[int] = []
	for id in direct_ids():
		now.append(id)
	for id in direct_ids():
		for other: Variant in _peer_links.get(id, []):
			if other is int and other != _id and other not in now:
				now.append(other)
	now.sort()
	_set_reachable(now)


func _set_reachable(now: Array[int]) -> void:
	var before := _reachable
	_reachable = now
	for id in before:
		if id not in now:
			peer_disconnected.emit(id)
	for id in now:
		if id not in before:
			peer_connected.emit(id)


## A direct peer that says it is linked to `to_id`.
func _relay_for(to_id: int) -> int:
	for id in direct_ids():
		if to_id in _peer_links.get(id, []):
			return id
	return -1


# --- Receiving ------------------------------------------------------------------------------

func _on_text(text: String, link: NetLink) -> void:
	var envelope: Variant = NetJson.parse(text)
	if envelope is not Dictionary:
		return
	match envelope.get("t"):
		"g": _deliver(envelope.get("f"), envelope.get("b"))
		"fwd": _on_forward(envelope)
		"links": _on_links(link, envelope.get("ids"))
		"rtc": _on_rtc(envelope)
		"part": _on_part(link, envelope)


func _deliver(from: Variant, body: Variant) -> void:
	if from is int and body is Dictionary:
		message_received.emit(from, body)


func _on_forward(envelope: Dictionary) -> void:
	var to: Variant = envelope.get("to")
	if to == _id:
		_deliver(envelope.get("f"), envelope.get("b"))
	elif to is int and _links.has(to) and _links[to].is_open:
		_links[to].send_text(NetJson.stringify(envelope))


func _on_links(link: NetLink, ids: Variant) -> void:
	if ids is not Array:
		return
	_peer_links[link.remote_id] = ids
	_recompute()
	# A newcomer builds the rest of the mesh through the first player it met.
	if joins_the_mesh:
		for other: Variant in ids:
			if other is int and other != _id and not _links.has(other) and not _building.has(other):
				_build_link(other)


## The newcomer asks `other` for a link, the setup messages passing through a shared peer.
func _build_link(other: int) -> void:
	var link := factory.offer(other, func(blob: String) -> void: _send_rtc(other, "offer", blob))
	if link == null:
		return
	_watch(link, other)
	_building[other] = [link, _clock]


func _on_rtc(envelope: Dictionary) -> void:
	var to: Variant = envelope.get("to")
	var from: Variant = envelope.get("f")
	if to is not int or from is not int:
		return
	if to != _id:
		if _links.has(to) and _links[to].is_open:
			_links[to].send_text(NetJson.stringify(envelope))
		return
	var blob := str(envelope.get("blob", ""))
	match envelope.get("k"):
		"offer":
			if _links.has(from):
				return
			var link := factory.answer(from, blob, func(answer_blob: String) -> void: _send_rtc(from, "answer", answer_blob))
			if link != null:
				_watch(link, from)
				_building[from] = [link, _clock]
		"answer":
			if _building.has(from):
				factory.complete(_building[from][0], blob)


func _send_rtc(to: int, kind: String, blob: String) -> void:
	var envelope := {"t": "rtc", "to": to, "f": _id, "k": kind, "blob": blob}
	var text := NetJson.stringify(envelope)
	var link: NetLink = _links.get(to)
	if link != null and link.is_open:
		link.send_text(text)
		return
	var via := _relay_for(to)  # A peer that says it is linked to `to`: it forwards.
	if via == -1 and not direct_ids().is_empty():
		via = direct_ids()[0]
	if via != -1:
		_links[via].send_text(text)


# --- Long messages --------------------------------------------------------------------------

func _send_text(link: NetLink, envelope: Dictionary, body_text: String) -> void:
	var text := NetJson.stringify(envelope)
	if text.length() <= MAX_PIECE:
		link.send_text(text)
		return
	_piece_counter += 1
	var count := ceili(text.length() / float(MAX_PIECE))
	for index in count:
		link.send_text(NetJson.stringify({"t": "part", "id": "%d-%d" % [_id, _piece_counter], "i": index, "of": count,
				"d": text.substr(index * MAX_PIECE, MAX_PIECE)}))


func _on_part(link: NetLink, envelope: Dictionary) -> void:
	var key := "%d:%s" % [link.remote_id, str(envelope.get("id"))]
	var of: Variant = envelope.get("of")
	var index: Variant = envelope.get("i")
	if of is not int or index is not int or of < 1 or of > 400 or index < 0 or index >= of:
		return
	var entry: Dictionary = _pieces.get(key, {"of": of, "got": {}})
	entry["got"][index] = str(envelope.get("d", ""))
	_pieces[key] = entry
	if entry["got"].size() == of:
		_pieces.erase(key)
		var text := ""
		for part_index in of:
			text += entry["got"][part_index]
		_on_text(text, link)
