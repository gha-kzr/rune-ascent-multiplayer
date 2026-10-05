extends TestCase
## The multiplayer fight on screen: it follows the match's log (placement, first turn, moves), turns
## the local player's clicks into proposals, and can open late and catch up.

const SCENE := preload("res://scenes/net/net_battle.tscn")


func _frames(count := 3) -> void:
	for i in count:
		await (Engine.get_main_loop() as SceneTree).process_frame


func _controller(rig: NetRig, seat: int) -> NetBattleController:
	var controller := SCENE.instantiate() as NetBattleController
	controller.setup_net(rig.sessions[seat])
	controller.settings.battle_speed = Settings.BattleSpeed.INSTANT
	(Engine.get_main_loop() as SceneTree).root.add_child(controller)
	return controller


func _fight(total := 2, per_side := 1) -> NetRig:
	var rig := NetRig.new()
	rig.start_match(total, per_side)
	return rig


func test_the_screen_opens_on_the_matchs_battle_in_placement() -> void:
	var rig := _fight()
	var controller := _controller(rig, 1)
	await _frames()
	assert_eq(controller.battle.state.units.size(), 2)
	assert_eq(controller.input_state, BattleController.State.PLACING)
	assert_eq(StateHash.of(controller.battle.state), StateHash.of(rig.sessions[1].state.battle.state), "the same battle as the session's")
	assert_true(controller.battle.state.pvp)
	assert_eq(controller._placement_zone(), controller.battle.state.zone, "side A places in its zone")
	var other := _controller(rig, 2)
	await _frames()
	assert_eq(other._placement_zone(), other.battle.state.zone_enemy, "side B in its own")
	controller.free()
	other.free()


func test_clicking_a_zone_cell_places_my_hero_through_the_host() -> void:
	var rig := _fight()
	var guest := _controller(rig, 2)
	await _frames()
	var cell: Vector2i = guest.battle.state.zone_enemy[4]
	guest.click_cell(cell)
	assert_eq(guest.input_state, BattleController.State.ANIMATING, "waiting for the host's answer")
	assert_ne(guest.battle.state.units[1].cell, cell, "nothing moves before the host says so")
	rig.net.flush()
	await _frames()
	assert_eq(guest.battle.state.units[1].cell, cell, "the placement came back and was applied")
	assert_eq(guest.input_state, BattleController.State.PLACING)
	assert_eq(rig.sessions[1].state.battle.state.units[1].cell, cell, "and the host has it too")
	guest.free()


func test_a_click_outside_my_zone_or_on_someone_elses_hero_does_nothing() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	await _frames()
	var before := rig.sessions[1].state.entry_count()
	host.click_cell(host.battle.state.zone_enemy[0])
	host.click_cell(Vector2i(0, 0))
	await _frames()
	assert_eq(rig.sessions[1].state.entry_count(), before, "no proposal was made")
	host.free()


func test_ready_waits_for_the_others_then_the_fight_starts() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	var guest := _controller(rig, 2)
	await _frames()
	host.end_turn()
	rig.net.flush()
	await _frames()
	assert_true(host._prompt_text().contains("Waiting") or host._prompt_text().contains("Ready"), "waiting for the others")
	assert_false(host.battle.state.started)
	guest.end_turn()
	rig.run(1.0)
	await _frames(5)
	assert_true(host.battle.state.started and guest.battle.state.started, "both views started the fight")
	var turn_unit := host.battle.state.current_unit().id
	var host_has_it := turn_unit == 0
	assert_eq(host.input_state, BattleController.State.IDLE if host_has_it else BattleController.State.ENEMY_TURN)
	assert_eq(guest.input_state, BattleController.State.ENEMY_TURN if host_has_it else BattleController.State.IDLE)
	host.free()
	guest.free()


func _both_ready(rig: NetRig, host: NetBattleController, guest: NetBattleController) -> void:
	host.end_turn()
	guest.end_turn()
	rig.run(1.0)
	await _frames(5)


func test_my_turn_ends_through_the_host_and_everyone_sees_the_next_turn() -> void:
	var rig := _fight()
	var host := _controller(rig, 1)
	var guest := _controller(rig, 2)
	await _frames()
	await _both_ready(rig, host, guest)
	var mine := host if host.battle.state.current_unit().id == 0 else guest
	var theirs := guest if mine == host else host
	var first_unit := mine.battle.state.current_unit().id
	mine.end_turn()
	rig.net.flush()
	await _frames(5)
	assert_ne(mine.battle.state.current_unit().id, first_unit, "the turn passed on my screen")
	assert_ne(theirs.battle.state.current_unit().id, first_unit, "and on theirs")
	assert_eq(StateHash.of(host.battle.state), StateHash.of(guest.battle.state), "the two views agree")
	assert_eq(StateHash.of(host.battle.state), StateHash.of(rig.sessions[1].state.battle.state), "and with the match")
	host.free()
	guest.free()


func test_a_view_opened_late_replays_the_log_and_shows_where_things_stand() -> void:
	var rig := _fight()
	for id in rig.sessions:
		rig.sessions[id].ai_delay = 0.0
	for id in rig.sessions:
		rig.sessions[id].set_placed(true)
	rig.run(0.5)
	rig.sessions[1].hand_to_ai(true)
	rig.sessions[2].hand_to_ai(true)
	rig.run(12.0)  # The AI plays a while.
	assert_true(rig.sessions[1].state.entry_count() > 12)
	var late := _controller(rig, 2)
	await _frames(5)
	assert_eq(StateHash.of(late.battle.state), StateHash.of(rig.sessions[2].state.battle.state), "caught up with everything")
	assert_true(late.battle.state.started)
	late.free()


func test_the_players_panel_tags_the_ai_and_the_ones_who_left() -> void:
	var rig := _fight(3, 1)
	var host := _controller(rig, 1)
	await _frames()
	rig.net.kill(3)
	rig.run(3.0)
	var texts := []
	for row in host._status._rows.get_children():
		texts.append((row as Label).text)
	assert_true(texts.any(func(t: String) -> bool: return t.contains("(you)")), "me")
	assert_true(texts.any(func(t: String) -> bool: return t.contains("(away)")), "the one who left")
	rig.run(float(rig.sessions[1].state.settings["grace"]) + 1.0)
	texts.clear()
	for row in host._status._rows.get_children():
		texts.append((row as Label).text)
	assert_true(texts.any(func(t: String) -> bool: return t.contains("(AI)")), "then the AI plays for them")
	host.free()
