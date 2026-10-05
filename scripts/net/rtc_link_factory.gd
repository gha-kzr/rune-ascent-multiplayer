class_name RtcLinkFactory
extends LinkFactory
## Makes WebRTC links (RtcLink).


func offer(remote_id: int, on_ready: Callable) -> NetLink:
	var link := RtcLink.new()
	link.remote_id = remote_id
	link.start_offer(on_ready)
	return link


func answer(remote_id: int, offer_blob: String, on_ready: Callable) -> NetLink:
	var link := RtcLink.new()
	link.remote_id = remote_id
	link.start_answer(offer_blob, on_ready)
	return link


func complete(link: NetLink, answer_blob: String) -> void:
	(link as RtcLink).complete(answer_blob)
