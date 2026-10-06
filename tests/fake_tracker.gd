class_name FakeTracker
extends RefCounted
## A tracker in memory, speaking the WebTorrent tracker protocol as far as the rooms use it: peers announce
## into a swarm (an info hash); an announce with offers hands each offer to another peer in the swarm; an
## announce with `to_peer_id` and an answer is forwarded to that peer. Sockets deliver when `flush()` runs.

var address := "wss://fake.tracker"
var up := true
var announces := 0
var _sockets: Array = []
var _swarms: Dictionary = {}
var _queue: Array = []


class Socket extends TrackerSocket:
	var server: FakeTracker
	var peer_id := ""

	func connect_to(address_: String) -> void:
		url = address_
		server._queue.append([self, "open"])

	func send_text(text: String) -> void:
		if is_open:
			server._queue.append([self, "from", text])

	func close() -> void:
		if is_open:
			is_open = false
			server._drop(self)
			closed.emit()


func make_socket() -> TrackerSocket:
	var socket := Socket.new()
	socket.server = self
	_sockets.append(socket)
	return socket


## The tracker goes down: every connection closes. (up = false keeps new ones from opening.)
func go_down() -> void:
	up = false
	for socket: Socket in _sockets.duplicate():
		if socket.is_open:
			socket.is_open = false
			_drop(socket)
			socket.closed.emit()


func flush() -> void:
	for round_index in 50:
		if _queue.is_empty():
			return
		var batch := _queue
		_queue = []
		for item: Array in batch:
			var socket: Socket = item[0]
			if item[1] == "open":
				if up:
					socket.is_open = true
					socket.opened.emit()
				else:
					socket.closed.emit()
			elif item[1] == "from" and socket.is_open:
				_handle(socket, str(item[2]))
			elif item[1] == "to" and socket.is_open:
				socket.text_received.emit(str(item[2]))


func _handle(socket: Socket, text: String) -> void:
	var message: Variant = NetJson.parse(text)
	if message is not Dictionary or message.get("action") != "announce":
		return
	announces += 1
	var hash_key := str(message.get("info_hash"))
	socket.peer_id = str(message.get("peer_id"))
	var swarm: Array = _swarms.get(hash_key, [])
	if not swarm.has(socket):
		swarm.append(socket)
	_swarms[hash_key] = swarm
	var offers: Variant = message.get("offers")
	if offers is Array:
		var others := swarm.filter(func(other: Socket) -> bool: return other != socket)
		for index in mini((offers as Array).size(), others.size()):
			var offer: Dictionary = offers[index]
			_queue.append([others[index], "to", NetJson.stringify({"action": "announce", "info_hash": hash_key, "peer_id": socket.peer_id,
					"offer_id": offer["offer_id"], "offer": offer["offer"]})])
	if message.get("answer") is Dictionary:
		for other: Socket in swarm:
			if other.peer_id == str(message.get("to_peer_id")):
				_queue.append([other, "to", NetJson.stringify({"action": "announce", "info_hash": hash_key, "peer_id": socket.peer_id,
						"offer_id": message["offer_id"], "answer": message["answer"]})])


func _drop(socket: Socket) -> void:
	for hash_key in _swarms:
		(_swarms[hash_key] as Array).erase(socket)
