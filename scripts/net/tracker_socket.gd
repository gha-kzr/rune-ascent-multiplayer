class_name TrackerSocket
extends RefCounted
## One WebSocket to a tracker, as far as the signalling code needs: connect, send text, receive text,
## closed. A real one wraps WebSocketPeer; tests use an in-memory fake.

signal opened
signal closed
signal text_received(text: String)

var url := ""
var is_open := false


func connect_to(address: String) -> void:
	url = address


func send_text(_text: String) -> void:
	pass


func poll() -> void:
	pass


func close() -> void:
	pass


## The real thing: a WebSocketPeer polled every frame.
class Real extends TrackerSocket:
	var _peer := WebSocketPeer.new()
	var _connecting := false
	var _done := false

	func connect_to(address: String) -> void:
		url = address
		if _peer.connect_to_url(address) == OK:
			_connecting = true
		else:
			_done = true
			closed.emit()

	func send_text(text: String) -> void:
		if is_open:
			_peer.send_text(text)

	func poll() -> void:
		if _done:
			return
		_peer.poll()
		match _peer.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				if not is_open:
					is_open = true
					_connecting = false
					opened.emit()
				while _peer.get_available_packet_count() > 0:
					text_received.emit(_peer.get_packet().get_string_from_utf8())
			WebSocketPeer.STATE_CLOSED:
				_done = true
				is_open = false
				closed.emit()

	func close() -> void:
		if not _done:
			_peer.close()
			_done = true
			is_open = false
			closed.emit()
