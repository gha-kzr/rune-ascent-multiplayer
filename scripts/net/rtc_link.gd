class_name RtcLink
extends NetLink
## A direct link over a WebRTC data channel (the browser's own WebRTC, built into the web export; a
## desktop build has none and the link closes at once). The offer and the answer are complete
## blobs: the description and every ICE candidate found, gathered before the blob is handed out (no trickling),
## so one message each way is all the other side needs. Public STUN servers let two players behind
## home routers find each other; there is no relay (TURN), so a few strict networks won't connect.
## Both ends make the same channel (negotiated, id 1), so there is nothing to wait for but "open".

const STUN_URLS: Array[String] = ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302", "stun:stun.cloudflare.com:3478"]
## False for local tests (no traffic to the public servers: same-machine players find each other without them).
static var use_stun := true
## How long to collect candidates once the first description exists, at most.
const GATHER_MAX_MSEC := 4000
## Candidates stop coming: the blob is complete this long after the last one.
const GATHER_QUIET_MSEC := 1200
## The link gives up when it isn't open this long after both sides have what they need.
const OPEN_TIMEOUT_MSEC := 30000

var _connection: WebRTCPeerConnection
var _channel: WebRTCDataChannel
var _candidates: Array = []
var _description := {}
var _on_ready := Callable()
var _blob_sent := false
var _gather_started := 0
var _last_candidate := 0
var _awaiting_since := 0


func start_offer(on_ready: Callable) -> void:
	_on_ready = on_ready
	if _setup():
		_connection.create_offer()


func start_answer(offer_blob: String, on_ready: Callable) -> void:
	_on_ready = on_ready
	var parsed: Variant = NetJson.parse(offer_blob)
	if parsed is not Dictionary or parsed.get("t") != "offer" or parsed.get("s") is not String or parsed.get("c") is not Array:
		_mark_closed()
		return
	if _setup():
		_connection.set_remote_description("offer", parsed["s"])  # The answer follows by itself.
		_add_candidates(parsed["c"])


## Finishes an offer's link with the answer blob.
func complete(answer_blob: String) -> void:
	var parsed: Variant = NetJson.parse(answer_blob)
	if _connection == null or parsed is not Dictionary or parsed.get("t") != "answer" or parsed.get("s") is not String or parsed.get("c") is not Array:
		_mark_closed()
		return
	_connection.set_remote_description("answer", parsed["s"])
	_add_candidates(parsed["c"])
	_awaiting_since = Time.get_ticks_msec()


func send_text(text: String) -> void:
	if is_open and _channel != null:
		_channel.put_packet(text.to_utf8_buffer())


func close() -> void:
	if _channel != null:
		_channel.close()
	if _connection != null:
		_connection.close()
	_mark_closed()


func poll() -> void:
	if _connection == null or is_closed:
		return
	_connection.poll()
	_check_blob()
	var state := _channel.get_ready_state() if _channel != null else WebRTCDataChannel.STATE_CLOSED
	if state == WebRTCDataChannel.STATE_OPEN:
		_mark_open()
		while _channel.get_available_packet_count() > 0:
			text_received.emit(_channel.get_packet().get_string_from_utf8())
	elif state == WebRTCDataChannel.STATE_CLOSING or state == WebRTCDataChannel.STATE_CLOSED:
		if is_open or _blob_sent:
			_mark_closed()
	var connection_state := _connection.get_connection_state()
	if connection_state == WebRTCPeerConnection.STATE_FAILED or connection_state == WebRTCPeerConnection.STATE_CLOSED:
		_mark_closed()
	elif not is_open and _awaiting_since > 0 and Time.get_ticks_msec() - _awaiting_since > OPEN_TIMEOUT_MSEC:
		close()


func _setup() -> bool:
	_connection = WebRTCPeerConnection.new()
	var servers: Array = [{"urls": STUN_URLS}] if use_stun else []
	var error := _connection.initialize({"iceServers": servers})
	if error != OK:
		push_warning("RtcLink: WebRTC isn't available here (%s)" % error_string(error))
		_mark_closed()
		return false
	_connection.session_description_created.connect(_on_description)
	_connection.ice_candidate_created.connect(_on_candidate)
	_channel = _connection.create_data_channel("game", {"negotiated": true, "id": 1, "ordered": true})
	if _channel == null:
		_mark_closed()
		return false
	return true


func _on_description(type: String, sdp: String) -> void:
	_connection.set_local_description(type, sdp)
	_description = {"t": type, "s": sdp}
	_gather_started = Time.get_ticks_msec()


func _on_candidate(media: String, index: int, candidate_name: String) -> void:
	_candidates.append([media, index, candidate_name])
	_last_candidate = Time.get_ticks_msec()


## Hands the blob out once every candidate is in (or the wait is over).
func _check_blob() -> void:
	if _blob_sent or _description.is_empty():
		return
	var waited := Time.get_ticks_msec() - _gather_started
	var done := _connection.get_gathering_state() == WebRTCPeerConnection.GATHERING_STATE_COMPLETE
	var quiet := not _candidates.is_empty() and Time.get_ticks_msec() - _last_candidate > GATHER_QUIET_MSEC
	if done or quiet or (not _candidates.is_empty() and waited > GATHER_MAX_MSEC) or waited > GATHER_MAX_MSEC * 3:
		_blob_sent = true
		_awaiting_since = Time.get_ticks_msec()
		var blob := {"t": _description["t"], "s": _description["s"], "c": _candidates}
		if _on_ready.is_valid():
			_on_ready.call(NetJson.stringify(blob))


func _add_candidates(list: Array) -> void:
	for candidate: Variant in list:
		if candidate is Array and candidate.size() == 3 and candidate[0] is String and candidate[1] is int and candidate[2] is String:
			_connection.add_ice_candidate(candidate[0], candidate[1], candidate[2])
