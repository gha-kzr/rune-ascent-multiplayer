class_name RoomSignaling
extends RefCounted
## Finding a room through public WebTorrent-style trackers, with nothing the tracker can read: the
## room is a "swarm" named by a hash of the room code, and everything that is sent in it (a joiner's
## WebRTC offer, a host's answer) is sealed with a key made from the code (RoomCrypto).
##
## The protocol is the trackers' own: an `announce` with `offers` hands each offer to a peer already in
## the swarm, which can answer it through the tracker (`to_peer_id`, `offer_id`, `answer`). So a joiner
## announces an offer, and a host that is in the swarm receives it and answers. Several trackers are used at
## once and whichever reports first wins; each message is handled once (by its offer id). A tracker that
## drops is retried with a growing pause (never faster than every few seconds), so a flaky relay costs nothing.
##
## `offer_received(offer_id, text, from_peer)` and `answer_received(offer_id, text, from_peer)` carry the
## unsealed text; what could not be unsealed (another room's, or forged) is dropped silently.

signal offer_received(offer_id: String, text: String, from_peer: String)
signal answer_received(offer_id: String, text: String, from_peer: String)
signal status_changed

const TRACKERS: Array[String] = ["wss://tracker.openwebtorrent.com", "wss://tracker.webtorrent.dev"]
const FIRST_RETRY := 4.0
const MAX_RETRY := 60.0
## How long an announced offer is kept alive (announced again now and then): a joiner waits this long.
const OFFER_LIFETIME := 240.0
const REANNOUNCE := 20.0
## Keeps a host in the swarm (trackers drop silent peers).
const KEEPALIVE := 60.0

var code := ""
var peer_id := ""
var info_hash := ""

var _make_socket: Callable
var _links: Array[Link] = []
var _offers: Dictionary[String, Dictionary] = {}
var _seen: Dictionary[String, bool] = {}
var _clock := 0.0
var _closed := false


class Link extends RefCounted:
	var socket: TrackerSocket
	var url := ""
	var retry_in := 0.0
	var pause := FIRST_RETRY
	var last_announce := -1000.0


## `make_socket`: a Callable returning a fresh TrackerSocket (the real one, or a fake).
func _init(room_code: String, make_socket: Callable) -> void:
	code = room_code
	peer_id = RoomCode.random_peer_id()
	info_hash = RoomCode.info_hash(room_code)
	_make_socket = make_socket


func start(urls: Array[String] = TRACKERS) -> void:
	for address in urls:
		var link := Link.new()
		link.url = address
		_links.append(link)
		_connect(link)


## How many trackers are connected right now.
func connected_count() -> int:
	return _links.filter(func(link: Link) -> bool: return link.socket != null and link.socket.is_open).size()


func tracker_count() -> int:
	return _links.size()


## Puts an offer in the room (sealed): it reaches the players in the swarm, who may answer it. Kept and
## announced again until retracted or OFFER_LIFETIME is over.
func publish_offer(offer_id: String, text: String) -> void:
	_offers[offer_id] = {"sealed": RoomCrypto.seal(text, code), "until": _clock + OFFER_LIFETIME}
	for link in _links:
		if _usable(link):
			_announce(link)


func retract_offer(offer_id: String) -> void:
	_offers.erase(offer_id)


## Answers an offer that came from `to_peer` (sealed).
func send_answer(to_peer: String, offer_id: String, text: String) -> void:
	var message := {"action": "announce", "info_hash": info_hash, "peer_id": peer_id, "to_peer_id": to_peer, "offer_id": offer_id,
			"answer": {"type": "answer", "sdp": RoomCrypto.seal(text, code)}}
	var line := NetJson.stringify(message)
	for link in _links:
		if _usable(link):
			link.socket.send_text(line)


## Announces with no offer: being in the swarm is what lets joiners' offers reach this player.
func join_swarm() -> void:
	for link in _links:
		if _usable(link):
			_announce(link)


func poll(delta: float) -> void:
	if _closed:
		return
	_clock += delta
	for id in _offers.keys():
		if _offers[id]["until"] < _clock:
			_offers.erase(id)
	for link in _links:
		if link.socket != null:
			link.socket.poll()
		elif link.retry_in > 0.0:
			link.retry_in -= delta
			if link.retry_in <= 0.0:
				_connect(link)
		var period := REANNOUNCE if not _offers.is_empty() else KEEPALIVE
		if _usable(link) and _clock - link.last_announce >= period:
			_announce(link)


func close() -> void:
	_closed = true
	for link in _links:
		if link.socket != null:
			link.socket.close()
	_links.clear()


func _usable(link: Link) -> bool:
	return not _closed and link.socket != null and link.socket.is_open


func _connect(link: Link) -> void:
	var socket: TrackerSocket = _make_socket.call()
	link.socket = socket
	socket.opened.connect(func() -> void:
		link.pause = FIRST_RETRY
		link.last_announce = -1000.0
		_announce(link)
		status_changed.emit())
	socket.closed.connect(func() -> void:
		if link.socket == socket:
			link.socket = null
			link.retry_in = link.pause
			link.pause = minf(link.pause * 2.0, MAX_RETRY)
			status_changed.emit())
	socket.text_received.connect(_on_text)
	socket.connect_to(link.url)


func _announce(link: Link) -> void:
	link.last_announce = _clock
	var offers: Array = []
	for id in _offers:
		offers.append({"offer_id": id, "offer": {"type": "offer", "sdp": _offers[id]["sealed"]}})
	var message := {"action": "announce", "info_hash": info_hash, "peer_id": peer_id, "numwant": 5, "uploaded": 0, "downloaded": 0,
			"left": 0, "event": "started", "offers": offers}
	link.socket.send_text(NetJson.stringify(message))


func _on_text(text: String) -> void:
	var message: Variant = NetJson.parse(text)
	if message is not Dictionary or message.get("action") != "announce" or message.get("info_hash") != info_hash:
		return
	var offer_id := str(message.get("offer_id", ""))
	var from := str(message.get("peer_id", ""))
	if offer_id.is_empty() or from.is_empty() or from == peer_id:
		return
	var offer: Variant = message.get("offer")
	var answer: Variant = message.get("answer")
	if offer is Dictionary and offer.get("sdp") is String:
		_deliver("offer", offer_id, from, offer["sdp"])
	elif answer is Dictionary and answer.get("sdp") is String:
		_deliver("answer", offer_id, from, answer["sdp"])


func _deliver(kind: String, offer_id: String, from: String, sealed: String) -> void:
	var key := "%s/%s/%s" % [kind, offer_id, from]
	if _seen.has(key):
		return  # The same message through another tracker.
	var text := RoomCrypto.open(sealed, code)
	if text.is_empty():
		return
	_seen[key] = true
	if kind == "offer":
		offer_received.emit(offer_id, text, from)
	else:
		answer_received.emit(offer_id, text, from)
