extends TestCase
## Joining by room code through a tracker (fake trackers and fake links): the host answers, the mesh
## builds, strangers and wrong codes get nowhere, a returning player gets their seat, and a new host
## takes over answering after a host swap.

var _fakes: FakeLinks
var _tracker: FakeTracker


func before_each_setup() -> void:
	_fakes = FakeLinks.new()
	_tracker = FakeTracker.new()


func _hub() -> MultiplayerHub:
	if _fakes == null:
		before_each_setup()
	var hub := MultiplayerHub.new()
	hub.factory = _fakes
	hub.socket_factory = func() -> TrackerSocket: return _tracker.make_socket()
	return hub


func _run(hubs: Array, seconds: float, step := 0.5) -> void:
	var elapsed := 0.0
	while elapsed < seconds:
		for hub: MultiplayerHub in hubs:
			if hub != null:
				hub._process(step)
		_fakes.flush()
		_tracker.flush()
		elapsed += step


func _write_token(room: String, seat: int, token: String) -> void:
	var file := ConfigFile.new()
	file.set_value("seat", "room", room)
	file.set_value("seat", "id", seat)
	file.set_value("seat", "token", token)
	file.save(MultiplayerHub.SESSION_FILE)


func test_a_player_joins_with_the_room_code_and_lands_in_the_hosts_lobby() -> void:
	var host := _hub()
	host.host_room("Alice")
	var guest := _hub()
	assert_eq(guest.join("Bob", RoomCode.pretty(host.room_code).to_upper()), "", "typed the way it was shown")
	assert_true(guest.session == null, "the answer is still on its way")
	_run([host, guest], 8)
	assert_true(guest.session != null and guest.session.is_synced, "joined")
	assert_eq(host.session.state.seat_ids(), [1, 2] as Array[int])
	assert_eq(guest.session.state.seats[1].name, "Alice")
	assert_eq(guest.room_code, host.room_code, "the guest knows the room too (for a host swap)")
	assert_true(host.session.state.fingerprint() == guest.session.state.fingerprint())


func test_three_players_join_by_code_and_the_mesh_builds_itself() -> void:
	var host := _hub()
	host.host_room("Alice")
	var bob := _hub()
	bob.join("Bob", host.room_code)
	_run([host, bob], 8)
	var carol := _hub()
	carol.join("Carol", host.room_code)
	_run([host, bob, carol], 8)
	assert_eq(host.session.state.seat_ids(), [1, 2, 3] as Array[int])
	assert_eq(carol.transport.direct_ids(), [1, 2] as Array[int], "a direct link to Bob too, built through the host")


func test_a_wrong_room_code_gets_nowhere() -> void:
	var host := _hub()
	host.host_room("Alice")
	var stranger := _hub()
	stranger.join("Eve", RoomCode.generate())
	_run([host, stranger], 20)
	assert_true(stranger.session == null, "no answer")
	assert_eq(host.session.state.seat_ids(), [1] as Array[int])


func test_something_that_is_not_a_code_is_refused_at_once() -> void:
	var guest := _hub()
	assert_ne(guest.join("Bob", "hello"), "")
	assert_ne(guest.join("Bob", ""), "")
	assert_ne(guest.join("Bob", "abcd-efgh"), "")


func test_nobody_joins_a_full_lobby_or_a_match_that_started_unless_they_left_it() -> void:
	var host := _hub()
	host.host_room("Alice")
	var bob := _hub()
	bob.join("Bob", host.room_code)
	_run([host, bob], 8)
	host.session.set_ready(true)
	bob.session.set_field("side", 1)
	_run([host, bob], 2)
	bob.session.set_ready(true)
	_run([host, bob], 2)
	host.session.start_match()
	_run([host, bob], 2)
	assert_eq(host.session.state.phase, MatchState.Phase.BATTLE)
	var late := _hub()
	late.join("Late", host.room_code)
	_run([host, bob, late], 15)
	assert_true(late.session == null, "the fight has begun: no new players")
	assert_eq(host.session.state.seat_ids(), [1, 2] as Array[int])


func test_a_player_who_left_comes_back_to_their_own_seat_with_their_token() -> void:
	var host := _hub()
	host.host_room("Alice")
	var bob := _hub()
	bob.join("Bob", host.room_code)
	_run([host, bob], 8)
	var bobs_token := bob.token
	host.session.configure("grace", 100)
	host.session.set_ready(true)
	bob.session.set_field("side", 1)
	_run([host, bob], 2)
	bob.session.set_ready(true)
	_run([host, bob], 2)
	host.session.start_match()
	_run([host, bob], 2)
	bob.leave()  # Bob's tab closes.
	_run([host], 5)
	assert_false(host.session.state.seats[2].connected)
	_write_token(host.room_code, 2, bobs_token)  # His browser still has it.
	var back := _hub()
	back.join("Bob", host.room_code)
	_run([host, back], 12)
	assert_true(back.session != null and back.session.is_synced, "back in the fight")
	assert_eq(back.session.my_id, 2, "the same seat")
	assert_true(host.session.state.seats[2].connected)


func test_a_browser_that_remembers_another_players_token_gets_a_new_one() -> void:
	var host := _hub()
	host.host_room("Alice")
	_write_token(host.room_code, 1, host.token)  # Two tabs of one browser: this tab "remembers" Alice's token.
	var second := _hub()
	second.join("Bob", host.room_code)
	_run([host, second], 8)
	assert_true(second.session != null and second.session.is_synced, "joined as a new player, not as Alice")
	assert_eq(second.session.my_id, 2)
	assert_ne(second.token, host.token, "with a token of their own")
	assert_eq(host.session.state.seat_ids(), [1, 2] as Array[int])


func test_after_a_host_swap_the_new_host_answers_new_players() -> void:
	var host := _hub()
	host.host_room("Alice")
	var bob := _hub()
	bob.join("Bob", host.room_code)
	_run([host, bob], 8)
	assert_true(bob.signaling == null, "only the host is in the swarm")
	var code := host.room_code
	host.leave()
	_run([bob], 12)
	assert_eq(bob.session.host_id, 2, "Bob is the host now")
	assert_true(bob.signaling != null, "so Bob answers join requests")
	var carol := _hub()
	carol.join("Carol", code)
	_run([bob, carol], 12)
	assert_true(carol.session != null and carol.session.is_synced, "Carol got into Bob's match")
	assert_eq(bob.session.state.seat_ids().size(), 2, "Bob and Carol (the first host left the lobby)")


func test_without_trackers_a_room_code_is_refused_with_a_hint() -> void:
	var guest := _hub()
	guest.use_trackers = false
	assert_ne(guest.join("Bob", "abcdefghjkmn"), "")
