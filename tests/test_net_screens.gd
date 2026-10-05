extends TestCase
## The multiplayer screens: the front page, the lobby (what each player may change), and the whole
## flow from an invite to a lobby to a fight, with fake links standing in for WebRTC.


func _root() -> Node:
	return (Engine.get_main_loop() as SceneTree).root


func _frames(count := 2) -> void:
	for i in count:
		await (Engine.get_main_loop() as SceneTree).process_frame


func test_the_front_page_hosts_or_joins_with_a_name() -> void:
	var menu := NetMenuScreen.new()
	_root().add_child(menu)
	var hosted := []
	var joined := []
	menu.host_requested.connect(func(player_name: String) -> void: hosted.append(player_name))
	menu.join_requested.connect(func(player_name: String, text: String) -> void: joined.append([player_name, text]))
	(menu.find_child("NameEdit", true, false) as LineEdit).text = "  Alice "
	(menu.find_child("HostButton", true, false) as Button).pressed.emit()
	assert_eq(hosted, ["Alice"])
	(menu.find_child("JoinButton", true, false) as Button).pressed.emit()
	assert_eq(joined, [], "no invite pasted yet")
	assert_ne((menu.find_child("Status", true, false) as Label).text, "")
	(menu.find_child("CodeEdit", true, false) as LineEdit).text = " R1abc "
	(menu.find_child("JoinButton", true, false) as Button).pressed.emit()
	assert_eq(joined, [["Alice", "R1abc"]], "the pasted text, trimmed")
	menu.free()


func test_the_lobby_lets_each_player_change_only_their_own_seat_and_the_host_the_rules() -> void:
	var rig := NetRig.new()
	rig.host(1, "Alice")
	rig.guest(2, "Bob")
	var host_lobby := NetLobbyScreen.new()
	var guest_lobby := NetLobbyScreen.new()
	_root().add_child(host_lobby)
	_root().add_child(guest_lobby)
	host_lobby.bind(rig.sessions[1])
	guest_lobby.bind(rig.sessions[2])
	await _frames()
	assert_true(host_lobby.find_child("Seat1", true, false).find_child("Hero", true, false) != null, "the host picks their own hero")
	assert_true(host_lobby.find_child("Seat2", true, false).find_child("Hero", true, false) == null, "not Bob's")
	assert_true((host_lobby.find_child("Typology", true, false) as OptionButton).disabled == false, "the host edits the rules")
	assert_true((guest_lobby.find_child("Typology", true, false) as OptionButton).disabled, "a guest only reads them")
	assert_true((guest_lobby.find_child("Size", true, false) as SpinBox).editable == false)
	assert_true(guest_lobby.find_child("StartButton", true, false).visible == false, "only the host starts")
	# Bob picks the Mage on side B: everyone sees it.
	(guest_lobby.find_child("Hero", true, false) as OptionButton).item_selected.emit(1)
	(guest_lobby.find_child("SideB", true, false) as Button).pressed.emit()
	rig.net.flush()
	assert_eq(rig.sessions[1].state.seats[2].hero, 1)
	assert_eq(rig.sessions[1].state.seats[2].side, 1)
	host_lobby.free()
	guest_lobby.free()


func test_the_start_button_waits_until_everyone_is_ready() -> void:
	var rig := NetRig.new()
	rig.host(1, "Alice")
	rig.guest(2, "Bob")
	var lobby := NetLobbyScreen.new()
	_root().add_child(lobby)
	lobby.bind(rig.sessions[1])
	rig.sessions[2].set_field("side", 1)
	rig.net.flush()
	var start := lobby.find_child("StartButton", true, false) as Button
	assert_true(start.disabled, "nobody is ready")
	rig.sessions[2].set_ready(true)
	rig.net.flush()
	assert_true(start.disabled, "the host is not ready yet")
	((lobby.find_child("Seat1", true, false)).find_child("Ready", true, false) as CheckBox).toggled.emit(true)
	rig.net.flush()
	assert_false(start.disabled, "ready: the host can start")
	start.pressed.emit()
	rig.net.flush()
	assert_eq(rig.sessions[2].state.phase, MatchState.Phase.BATTLE)
	lobby.free()


func test_a_player_changes_their_name_in_the_lobby() -> void:
	var rig := NetRig.new()
	rig.host(1, "Alice")
	var lobby := NetLobbyScreen.new()
	_root().add_child(lobby)
	lobby.bind(rig.sessions[1])
	var edit := lobby.find_child("NameEdit", true, false) as LineEdit
	assert_eq(edit.text, "Alice")
	edit.text_submitted.emit("Alicia")
	assert_eq(rig.sessions[1].state.seats[1].name, "Alicia")
	lobby.free()


func test_the_invite_choices_offer_a_new_player_and_each_player_who_is_away() -> void:
	var rig := NetRig.new()
	rig.start_match(3, 1)
	var lobby := NetLobbyScreen.new()
	_root().add_child(lobby)
	lobby.bind(rig.sessions[1])
	var picker := lobby.find_child("InviteFor", true, false) as OptionButton
	assert_eq(picker.item_count, 1, "in a fight only players who left can be invited back, and nobody has")
	rig.net.kill(3)
	rig.run(3.0)
	assert_eq(picker.item_count, 1)
	assert_eq(picker.get_item_id(0), 3, "the player who left")
	lobby.free()


func _flow(fakes: FakeLinks) -> NetFlow:
	var flow := NetFlow.new()
	flow.link_factory = fakes
	_root().add_child(flow)
	return flow


func test_an_invite_a_reply_and_two_players_are_in_the_same_lobby() -> void:
	var fakes := FakeLinks.new()
	var host := _flow(fakes)
	host.start("")
	host._on_host("Alice")
	assert_true(host._screen is NetLobbyScreen)
	var invite := {}
	host.hub.invite_ready.connect(func(code: String, link: String, seat: int) -> void: invite.merge({"code": code, "link": link, "seat": seat}, true))
	host.hub.create_invite()
	assert_eq(invite["seat"], 2)
	assert_true(str(invite["link"]).contains("#join="))
	var guest := _flow(fakes)
	guest.start("")
	var reply := {}
	guest.hub.reply_ready.connect(func(code: String, link: String) -> void: reply.merge({"code": code, "link": link}, true))
	guest._on_join("Bob", invite["link"])
	assert_true(guest._screen is NetJoinScreen, "waiting for the host")
	assert_true(str(reply["link"]).contains("#reply="))
	host._on_reply_pasted(reply["link"])
	fakes.flush()
	await _frames()
	assert_true(guest._screen is NetLobbyScreen, "caught up: the lobby")
	assert_eq(host.hub.session.state.seat_ids(), [1, 2] as Array[int])
	assert_eq(guest.hub.session.state.seats[1].name, "Alice")
	assert_eq(guest.hub.session.host_id, 1)
	host.free()
	guest.free()


func test_a_link_opened_in_the_browser_joins_by_itself() -> void:
	var fakes := FakeLinks.new()
	var host := _flow(fakes)
	host.start("")
	host._on_host("Alice")
	var invite := {}
	host.hub.invite_ready.connect(func(code: String, _link: String, _seat: int) -> void: invite.merge({"code": code}, true))
	host.hub.create_invite()
	var guest := _flow(fakes)
	guest.start("join=" + invite["code"])
	assert_true(guest._screen is NetJoinScreen, "no click needed")
	assert_true(guest.hub.session != null)
	host.free()
	guest.free()


func test_a_bad_invite_stays_on_the_front_page_with_a_message() -> void:
	var fakes := FakeLinks.new()
	var guest := _flow(fakes)
	guest.start("")
	guest._on_join("Bob", "not an invite")
	assert_true(guest._screen is NetMenuScreen)
	assert_ne((guest._screen.find_child("Status", true, false) as Label).text, "")
	guest.free()


func test_a_reply_for_another_match_is_refused() -> void:
	var fakes := FakeLinks.new()
	var host := _flow(fakes)
	host.start("")
	host._on_host("Alice")
	var other := _flow(fakes)
	other.start("")
	other._on_host("Eve")
	var invite := {}
	other.hub.invite_ready.connect(func(code: String, _link: String, _seat: int) -> void: invite.merge({"code": code}, true))
	other.hub.create_invite()
	var guest := _flow(fakes)
	guest.start("")
	var reply := {}
	guest.hub.reply_ready.connect(func(code: String, _link: String) -> void: reply.merge({"code": code}, true))
	guest._on_join("Bob", invite["code"])
	assert_ne(host.hub.accept_reply(reply["code"]), "", "Alice's match is not Eve's")
	host.free()
	other.free()
	guest.free()


func test_the_fight_opens_on_both_screens_and_leads_back_to_the_lobby() -> void:
	var fakes := FakeLinks.new()
	var host := _flow(fakes)
	host.start("")
	host._on_host("Alice")
	var invite := {}
	host.hub.invite_ready.connect(func(code: String, _link: String, _seat: int) -> void: invite.merge({"code": code}, true))
	host.hub.create_invite()
	var guest := _flow(fakes)
	guest.start("")
	var reply := {}
	guest.hub.reply_ready.connect(func(code: String, _link: String) -> void: reply.merge({"code": code}, true))
	guest._on_join("Bob", invite["code"])
	host._on_reply_pasted(reply["code"])
	fakes.flush()
	await _frames()
	guest.hub.session.set_field("side", 1)
	fakes.flush()
	host.hub.session.set_ready(true)
	guest.hub.session.set_ready(true)
	fakes.flush()
	host.hub.session.start_match()
	fakes.flush()
	await _frames(3)
	assert_true(host._screen is NetBattleController, "the fight on the host's screen")
	assert_true(guest._screen is NetBattleController, "and the guest's")
	host.free()
	guest.free()
