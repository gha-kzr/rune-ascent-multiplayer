extends TestCase
## The mesh: links made from invites, the rest of the mesh built by itself, messages passing through a
## player when two can't link directly, and long messages in pieces.


## Player `id` joins through `via` (an existing player), by the two-step invite.
func _join(factory: FakeLinks, players: Dictionary, id: int, via: int) -> MeshTransport:
	var newcomer := MeshTransport.new(factory, id)
	var offer := {"blob": ""}
	players[via].create_invite(id, func(blob: String) -> void: offer["blob"] = blob)
	var answer := {"blob": ""}
	newcomer.accept_invite(via, offer["blob"], func(blob: String) -> void: answer["blob"] = blob)
	players[via].complete_invite(id, answer["blob"])
	players[id] = newcomer
	factory.flush()
	return newcomer


func _first(factory: FakeLinks, players: Dictionary) -> MeshTransport:
	players[1] = MeshTransport.new(factory, 1)
	return players[1]


func test_an_invite_links_two_players_and_messages_flow() -> void:
	var factory := FakeLinks.new()
	var players := {}
	_first(factory, players)
	_join(factory, players, 2, 1)
	assert_eq(players[1].reachable_ids(), [2] as Array[int])
	assert_eq(players[2].reachable_ids(), [1] as Array[int])
	var received := []
	players[2].message_received.connect(func(from: int, message: Dictionary) -> void: received.append([from, message]))
	players[1].send(2, {"m": "hi", "n": 5})
	factory.flush()
	assert_eq(received, [[1, {"m": "hi", "n": 5}]])


func test_a_third_player_is_linked_to_everyone_through_the_first_contact() -> void:
	var factory := FakeLinks.new()
	var players := {}
	_first(factory, players)
	_join(factory, players, 2, 1)
	_join(factory, players, 3, 1)
	for id in [1, 2, 3]:
		var expected: Array[int] = []
		for other in [1, 2, 3]:
			if other != id:
				expected.append(other)
		assert_eq(players[id].reachable_ids(), expected, "player %d reaches everyone" % id)
	assert_eq(players[3].direct_ids(), [1, 2] as Array[int], "a direct link to player 2 too, built through player 1")
	assert_eq(players[2].direct_ids(), [1, 3] as Array[int])


func test_four_players_form_a_full_mesh() -> void:
	var factory := FakeLinks.new()
	var players := {}
	_first(factory, players)
	_join(factory, players, 2, 1)
	_join(factory, players, 3, 2)
	_join(factory, players, 4, 3)
	for id in [1, 2, 3, 4]:
		assert_eq(players[id].direct_ids().size(), 3, "player %d is linked to the other three" % id)


func test_when_the_host_vanishes_the_others_stay_linked() -> void:
	var factory := FakeLinks.new()
	var players := {}
	_first(factory, players)
	_join(factory, players, 2, 1)
	_join(factory, players, 3, 1)
	var lost := []
	players[3].peer_disconnected.connect(func(id: int) -> void: lost.append(id))
	players[1].close()
	factory.flush()
	assert_eq(lost, [1])
	assert_eq(players[3].reachable_ids(), [2] as Array[int])
	var received := []
	players[2].message_received.connect(func(from: int, message: Dictionary) -> void: received.append(from))
	players[3].send(2, {"m": "still here"})
	factory.flush()
	assert_eq(received, [3])


func test_a_message_goes_through_a_player_when_two_cannot_link() -> void:
	var factory := FakeLinks.new()
	var players := {}
	_first(factory, players)
	_join(factory, players, 2, 1)
	_join(factory, players, 3, 1)
	var lost := []
	players[3].peer_disconnected.connect(func(id: int) -> void: lost.append(id))
	# The direct link between 2 and 3 breaks.
	players[3]._links[2].close()
	factory.flush()
	assert_eq(players[3].direct_ids(), [1] as Array[int])
	assert_eq(players[3].reachable_ids(), [1, 2] as Array[int], "player 2 is still reachable, through player 1")
	assert_eq(lost, [], "nobody was lost")
	var received := []
	players[2].message_received.connect(func(from: int, message: Dictionary) -> void: received.append([from, message["m"]]))
	players[3].send(2, {"m": "relayed"})
	factory.flush()
	assert_eq(received, [[3, "relayed"]])


func test_a_pair_that_cannot_link_stays_connected_through_the_first_contact() -> void:
	var factory := FakeLinks.new()
	var players := {}
	_first(factory, players)
	_join(factory, players, 2, 1)
	factory.answers_left = 1  # Player 3's invite is answered, then nobody answers: it can't link to player 2.
	_join(factory, players, 3, 1)
	assert_eq(players[3].direct_ids(), [1] as Array[int], "no direct link to player 2")
	assert_eq(players[3].reachable_ids(), [1, 2] as Array[int], "but reachable through the host")
	var received := []
	players[3].message_received.connect(func(from: int, message: Dictionary) -> void: received.append(from))
	players[2].send(3, {"m": "x"})
	factory.flush()
	assert_eq(received, [2])


func test_a_long_message_arrives_whole_in_pieces() -> void:
	var factory := FakeLinks.new()
	var players := {}
	_first(factory, players)
	_join(factory, players, 2, 1)
	var big: Array = []
	for i in 6000:
		big.append({"n": i, "text": "entry number %d" % i})
	var received := []
	players[2].message_received.connect(func(_from: int, message: Dictionary) -> void: received.append(message))
	players[1].send(2, {"m": "entries", "list": big})
	factory.flush()
	assert_eq(received.size(), 1)
	assert_eq((received[0]["list"] as Array).size(), 6000)
	assert_eq(received[0]["list"][5999]["n"], 5999)


func test_garbage_on_the_wire_is_ignored() -> void:
	var factory := FakeLinks.new()
	var players := {}
	_first(factory, players)
	_join(factory, players, 2, 1)
	var received := []
	players[2].message_received.connect(func(_from: int, message: Dictionary) -> void: received.append(message))
	for bad in ["", "not json", "[]", "{}", "{\"t\":\"g\"}", "{\"t\":\"fwd\",\"to\":9}", "{\"t\":\"part\",\"id\":1,\"i\":9,\"of\":2,\"d\":\"x\"}",
			"{\"t\":\"rtc\"}", "{\"t\":\"links\",\"ids\":5}"]:
		players[2]._links[1].text_received.emit(bad)
	assert_eq(received, [])
	assert_eq(players[2].reachable_ids(), [1] as Array[int])
