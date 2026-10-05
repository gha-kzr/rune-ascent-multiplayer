class_name LinkFactory
extends RefCounted
## Makes links. Connecting two players takes two blobs of text (an offer, then an answer) that
## something must carry from one to the other: a copy and paste, a public tracker, or the mesh itself
## (through a player both can reach). The blob's contents are the factory's business.


## Starts a link to `remote_id`. `on_ready(blob)` gets the offer to hand over when it is complete;
## the other side's answer then goes to link.complete(answer). Null when links can't be made here.
func offer(_remote_id: int, _on_ready: Callable) -> NetLink:
	return null


## Answers an offer from `remote_id`. `on_ready(blob)` gets the answer to send back.
func answer(_remote_id: int, _offer_blob: String, _on_ready: Callable) -> NetLink:
	return null


## Finishes a link that `offer` made, with the other side's answer.
func complete(_link: NetLink, _answer_blob: String) -> void:
	pass
