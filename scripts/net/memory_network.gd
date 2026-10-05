class_name MemoryNetwork
extends RefCounted
## A fake network inside one process, for tests: transports are linked by hand (`connect_peers`,
## `cut`, `kill`), messages are queued and delivered when `deliver()` runs (so a test decides when
## time passes), always as JSON text like a real network. A message to a peer with no direct
## link goes through one peer linked to both (like the relay of the real transport), a round later.

var _transports: Dictionary[int, Transport] = {}
var _links: Dictionary[String, bool] = {}
## [from, to, text, rounds_to_wait]
var _queue: Array = []
## Messages sent so far, by kind ("m" field), for tests that count traffic.
var sent_kinds: Dictionary[String, int] = {}


class Transport extends NetTransport:
	var network: MemoryNetwork
	var id := 0
	var reachable: Array[int] = []
	var closed := false

	func local_id() -> int:
		return id

	func reachable_ids() -> Array[int]:
		return reachable.duplicate()

	func send(to_id: int, message: Dictionary) -> void:
		if closed:
			return
		network._enqueue(id, to_id, message)

	func close() -> void:
		network.kill(id)


func transport(id: int) -> Transport:
	if not _transports.has(id):
		var made := Transport.new()
		made.network = self
		made.id = id
		_transports[id] = made
	return _transports[id]


func connect_peers(a: int, b: int) -> void:
	transport(a)
	transport(b)
	_links[_key(a, b)] = true
	_refresh()


## Breaks the link between two peers (they may still reach each other through a third).
func cut(a: int, b: int) -> void:
	_links.erase(_key(a, b))
	_queue = _queue.filter(func(item: Array) -> bool: return not ((item[0] == a and item[1] == b) or (item[0] == b and item[1] == a)))
	_refresh()


## The peer drops off the network: every link of it goes, nothing more is sent or received.
func kill(id: int) -> void:
	if not _transports.has(id):
		return
	_transports[id].closed = true
	for key in _links.keys():
		if _linked(key, id):
			_links.erase(key)
	_queue = _queue.filter(func(item: Array) -> bool: return item[0] != id and item[1] != id)
	_refresh()


func _enqueue(from: int, to: int, message: Dictionary) -> void:
	var kind := str(message.get("m", "?"))
	sent_kinds[kind] = sent_kinds.get(kind, 0) + 1
	var text := NetJson.stringify(message)
	if _links.has(_key(from, to)):
		_queue.append([from, to, text, 0])
	elif to in _transports[from].reachable:
		_queue.append([from, to, text, 1])  # Through a peer: one round later.


## Delivers what is queued now (messages sent while delivering wait for the next call). Returns how
## many were delivered.
func deliver() -> int:
	var batch := _queue
	_queue = []
	var delivered := 0
	for item: Array in batch:
		if item[3] > 0:
			item[3] -= 1
			_queue.append(item)
			continue
		var target: Transport = _transports.get(item[1])
		if target == null or target.closed or item[0] not in target.reachable:
			continue
		delivered += 1
		var message: Variant = NetJson.parse(item[2])
		if message is Dictionary:
			target.message_received.emit(item[0], message)
	return delivered


## Delivers until nothing is left to deliver.
func flush(max_rounds := 200) -> void:
	for round_index in max_rounds:
		if deliver() == 0 and _queue.is_empty():
			return


func _refresh() -> void:
	for id in _transports:
		var transport := _transports[id]
		var now: Array[int] = []
		if not transport.closed:
			for other in _transports:
				if other != id and not _transports[other].closed and _reaches(id, other):
					now.append(other)
		now.sort()
		var before := transport.reachable
		transport.reachable = now
		for other in before:
			if other not in now:
				transport.peer_disconnected.emit(other)
		for other in now:
			if other not in before:
				transport.peer_connected.emit(other)


func _reaches(a: int, b: int) -> bool:
	if _links.has(_key(a, b)):
		return true
	for middle in _transports:
		if middle != a and middle != b and not _transports[middle].closed and _links.has(_key(a, middle)) and _links.has(_key(middle, b)):
			return true
	return false


static func _key(a: int, b: int) -> String:
	return "%d-%d" % [mini(a, b), maxi(a, b)]


static func _linked(key: String, id: int) -> bool:
	var parts := key.split("-")
	return int(parts[0]) == id or int(parts[1]) == id
