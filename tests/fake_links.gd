class_name FakeLinks
extends LinkFactory
## Test double for links: pairs of in-memory links, whose messages move when the test says so.

var _queue: Array = []
var _pending: Dictionary[int, FakeLink] = {}
var _counter := 0
## How many more offers get answered (-1: all); the rest are refused, so a test can make two players unable to link.
var answers_left := -1


class FakeLink extends NetLink:
	var hub: FakeLinks
	var peer: FakeLink

	func send_text(text: String) -> void:
		if is_open and peer != null:
			hub._queue.append([peer, text])

	func close() -> void:
		if is_closed:
			return
		_mark_closed()
		if peer != null and not peer.is_closed:
			hub._queue.append([peer, null])


func offer(_remote_id: int, on_ready: Callable) -> NetLink:
	var link := FakeLink.new()
	link.hub = self
	_counter += 1
	_pending[_counter] = link
	on_ready.call("offer:%d" % _counter)
	return link


func answer(_remote_id: int, offer_blob: String, on_ready: Callable) -> NetLink:
	var token := int(offer_blob.trim_prefix("offer:"))
	if answers_left == 0 or not _pending.has(token):
		return null
	if answers_left > 0:
		answers_left -= 1
	var link := FakeLink.new()
	link.hub = self
	link.peer = _pending[token]
	_pending[token].peer = link
	on_ready.call("answer:%d" % token)
	return link


func complete(link: NetLink, answer_blob: String) -> void:
	var fake := link as FakeLink
	if fake.peer == null or not answer_blob.begins_with("answer:"):
		return
	_queue.append([fake, "open"])
	_queue.append([fake.peer, "open"])


## Moves everything that is waiting (and what that causes) until quiet.
func flush(max_rounds := 200) -> void:
	for round_index in max_rounds:
		if _queue.is_empty():
			return
		var batch := _queue
		_queue = []
		for item: Array in batch:
			var link: FakeLink = item[0]
			if item[1] == null:
				link._mark_closed()
			elif item[1] is String and item[1] == "open":
				link._mark_open()
			elif not link.is_closed:
				link.text_received.emit(item[1])
