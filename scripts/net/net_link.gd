class_name NetLink
extends RefCounted
## One direct connection to another player: a pipe for text messages, whatever carries it (a WebRTC data
## channel, or a fake in tests). The mesh (MeshTransport) builds everything else on these.
## A link starts connecting; `opened` fires once when messages can flow, `closed` once when they can't
## any more.

signal opened
signal closed
signal text_received(text: String)

var remote_id := 0
var is_open := false
var is_closed := false


## Sends text to the other end (dropped when the link isn't open).
func send_text(_text: String) -> void:
	pass


func close() -> void:
	pass


## Called every frame by the transport (links that need polling do it here).
func poll() -> void:
	pass


func _mark_open() -> void:
	if not is_open and not is_closed:
		is_open = true
		opened.emit()


func _mark_closed() -> void:
	if not is_closed:
		is_closed = true
		is_open = false
		closed.emit()
