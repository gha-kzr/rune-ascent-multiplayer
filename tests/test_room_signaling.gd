extends TestCase
## Finding a room through trackers: offers and answers sealed with the room code, several trackers
## at once, a tracker that drops and comes back, and nothing forged getting through.

const CODE := "abcdefghjkmn"


func _signaling(trackers: Array[FakeTracker], code := CODE) -> RoomSignaling:
	var signaling := RoomSignaling.new(code, func() -> TrackerSocket: return trackers[0].make_socket())
	# One socket per tracker: the factory hands out the next tracker's socket each time.
	var index := {"next": 0}
	signaling = RoomSignaling.new(code, func() -> TrackerSocket:
		var tracker := trackers[index["next"] % trackers.size()]
		index["next"] += 1
		return tracker.make_socket())
	var urls: Array[String] = []
	for tracker in trackers:
		urls.append(tracker.address)
	signaling.start(urls)
	return signaling


func _run(signalers: Array, trackers: Array, seconds: float, step := 1.0) -> void:
	var elapsed := 0.0
	while elapsed < seconds:
		for signaling: RoomSignaling in signalers:
			signaling.poll(step)
		for tracker: FakeTracker in trackers:
			tracker.flush()
		elapsed += step


func test_a_joiners_offer_reaches_the_host_and_the_answer_comes_back() -> void:
	var tracker := FakeTracker.new()
	var host := _signaling([tracker])
	var joiner := _signaling([tracker])
	var got := {"offers": [], "answers": []}
	host.offer_received.connect(func(id: String, text: String, from: String) -> void:
		got["offers"].append([id, text])
		host.send_answer(from, id, "the answer to " + text))
	joiner.answer_received.connect(func(id: String, text: String, _from: String) -> void: got["answers"].append([id, text]))
	_run([host, joiner], [tracker], 3)  # Both connected; the host is in the swarm.
	joiner.publish_offer("offer-1", "my offer {with: addresses}")
	_run([host, joiner], [tracker], 3)
	assert_eq(got["offers"], [["offer-1", "my offer {with: addresses}"]])
	assert_eq(got["answers"], [["offer-1", "the answer to my offer {with: addresses}"]])


func test_the_tracker_sees_only_sealed_text() -> void:
	var tracker := FakeTracker.new()
	var host := _signaling([tracker])
	var joiner := _signaling([tracker])
	var seen: Array[String] = []
	var socket := tracker.make_socket()
	_run([host, joiner], [tracker], 2)
	joiner.publish_offer("offer-1", "SECRET-SDP 192.168.1.20")
	# Whatever the tracker queued for delivery never contains the plain text.
	for item: Array in tracker._queue:
		if item.size() > 2:
			seen.append(str(item[2]))
	_run([host, joiner], [tracker], 1)
	assert_true(seen.size() > 0, "something was sent")
	assert_false(" ".join(seen).contains("SECRET-SDP"), "sealed on the wire")
	assert_true(socket != null)


func test_the_same_offer_through_two_trackers_is_handled_once() -> void:
	var first := FakeTracker.new()
	first.address = "wss://one"
	var second := FakeTracker.new()
	second.address = "wss://two"
	var host := _signaling([first, second])
	var joiner := _signaling([first, second])
	var offers := []
	host.offer_received.connect(func(id: String, _text: String, _from: String) -> void: offers.append(id))
	_run([host, joiner], [first, second], 3)
	joiner.publish_offer("offer-1", "x")
	_run([host, joiner], [first, second], 3)
	assert_eq(offers, ["offer-1"], "once, whichever tracker was first")
	assert_eq(host.connected_count(), 2)


func test_a_message_sealed_with_another_code_or_forged_is_dropped() -> void:
	var tracker := FakeTracker.new()
	var host := _signaling([tracker])
	var offers := []
	host.offer_received.connect(func(id: String, _text: String, _from: String) -> void: offers.append(id))
	_run([host], [tracker], 2)
	var forged := {"action": "announce", "info_hash": host.info_hash, "peer_id": "x".repeat(20), "offer_id": "evil",
			"offer": {"type": "offer", "sdp": RoomCrypto.seal("pwned", "zzzzzzzzzzzz")}}
	host._on_text(NetJson.stringify(forged))
	forged["offer"]["sdp"] = "plain text, not sealed"
	host._on_text(NetJson.stringify(forged))
	forged["info_hash"] = "other room".rpad(20, "_")
	forged["offer"]["sdp"] = RoomCrypto.seal("hi", CODE)
	host._on_text(NetJson.stringify(forged))
	host._on_text("not json")
	host._on_text("[]")
	assert_eq(offers, [], "nothing forged got through")
	forged["info_hash"] = host.info_hash
	host._on_text(NetJson.stringify(forged))
	assert_eq(offers, ["evil"], "sealed with the right code, it is accepted (the room's own)")


func test_a_tracker_that_drops_is_retried_slowly_and_offers_are_announced_again() -> void:
	var tracker := FakeTracker.new()
	var host := _signaling([tracker])
	var joiner := _signaling([tracker])
	var offers := []
	host.offer_received.connect(func(id: String, _text: String, _from: String) -> void: offers.append(id))
	_run([host, joiner], [tracker], 2)
	joiner.publish_offer("offer-1", "x")
	_run([host, joiner], [tracker], 2)
	assert_eq(offers.size(), 1)
	tracker.go_down()
	assert_eq(host.connected_count(), 0)
	var before := tracker.announces
	_run([host, joiner], [tracker], 30)
	assert_eq(tracker.announces, before, "nothing is sent to a tracker that is down")
	tracker.up = true
	_run([host, joiner], [tracker], 70)
	assert_eq(host.connected_count(), 1, "back after the pause")
	assert_true(tracker.announces > before)
	assert_true(tracker.announces - before < 25, "retries and announces stay few: %d in 100 s" % (tracker.announces - before))


func test_an_offer_waits_for_a_host_that_arrives_later() -> void:
	var tracker := FakeTracker.new()
	var joiner := _signaling([tracker])
	_run([joiner], [tracker], 2)
	joiner.publish_offer("offer-1", "x")
	_run([joiner], [tracker], 30)  # Nobody is there to take it.
	var host := _signaling([tracker])
	var offers := []
	host.offer_received.connect(func(id: String, _text: String, _from: String) -> void: offers.append(id))
	_run([host, joiner], [tracker], 25)
	assert_eq(offers, ["offer-1"], "announced again while it lives, so the late host gets it")


func test_an_offer_stops_being_announced_when_it_expires_or_is_retracted() -> void:
	var tracker := FakeTracker.new()
	var joiner := _signaling([tracker])
	_run([joiner], [tracker], 2)
	joiner.publish_offer("offer-1", "x")
	joiner.publish_offer("offer-2", "y")
	joiner.retract_offer("offer-2")
	_run([joiner], [tracker], RoomSignaling.OFFER_LIFETIME + 10.0)
	assert_true(joiner._offers.is_empty(), "both gone")
	var before := tracker.announces
	_run([joiner], [tracker], 100)
	assert_true(tracker.announces - before <= 3, "only keep-alives now")


func test_another_rooms_peers_never_meet() -> void:
	var tracker := FakeTracker.new()
	var host := _signaling([tracker], "abcdefghjkmn")
	var stranger := _signaling([tracker], "abcdefghjkmp")
	var offers := []
	host.offer_received.connect(func(id: String, _text: String, _from: String) -> void: offers.append(id))
	_run([host, stranger], [tracker], 2)
	stranger.publish_offer("offer-1", "x")
	_run([host, stranger], [tracker], 5)
	assert_eq(offers, [], "different swarms")
