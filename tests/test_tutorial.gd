extends TestCase
## The guided first steps: the spotlight overlay, and the battle's steps that wait for the action.

const BATTLE_SCENE := preload("res://scenes/battle/battle.tscn")


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func after_each_clean() -> void:
	Engine.time_scale = 1.0


func _controller(tutorial: Tutorial, hero_mp := 3) -> BattleController:
	Engine.time_scale = 10.0
	var hero := BattleFixtures.unit("P0", 200, hero_mp, 6, 40)
	hero.spells = [BattleFixtures.damage_spell(2, 1, 5, 3)] as Array[SpellData]
	var enemy := BattleFixtures.unit("E0", 100, 3, 6, 400)
	enemy.spells = [BattleFixtures.damage_spell(2, 1, 5, 1)] as Array[SpellData]
	var controller := BATTLE_SCENE.instantiate() as BattleController
	controller.rng_seed = 7
	controller.encounter = BattleFixtures.encounter("0p 0 0 0e", [enemy])
	controller.players = [hero] as Array[UnitData]
	controller.tutorial = tutorial
	_tree().root.add_child(controller)
	return controller


func _wait_state(controller: BattleController, state: BattleController.State) -> bool:
	for i in 1500:
		if controller.input_state == state:
			return true
		await _tree().process_frame
	return false


func _step_id(controller: BattleController) -> String:
	return str(controller._step.get("id", ""))


# --- Tutorial rules ---

func test_steps_are_done_once_kept_in_the_settings_and_skip_marks_them_all() -> void:
	var settings := Settings.new()
	var tutorial := Tutorial.new(settings)
	assert_eq(tutorial.next_step(Tutorial.BATTLE_STEPS)["id"], "ready")
	tutorial.complete("ready")
	tutorial.complete("ready")
	assert_eq(settings.dismissed_hints, ["tutorial_ready"] as Array[String], "no duplicates")
	assert_eq(tutorial.next_step(Tutorial.BATTLE_STEPS)["id"], "move")
	tutorial.skip_all()
	assert_eq(tutorial.next_step(Tutorial.BATTLE_STEPS), {})
	assert_eq(tutorial.next_step(Tutorial.HUB_STEPS), {})
	Hints.new(settings).reset()
	assert_eq(tutorial.next_step(Tutorial.BATTLE_STEPS)["id"], "ready", "Show hints again replays it")


func test_a_step_lets_through_its_own_action_and_the_harmless_ones_around_it() -> void:
	var ready := Tutorial.BATTLE_STEPS[0]
	assert_true(Tutorial.allows(ready, Tutorial.Action.READY) and Tutorial.allows(ready, Tutorial.Action.PLACE))
	assert_false(Tutorial.allows(ready, Tutorial.Action.CAST))
	var cast := Tutorial.BATTLE_STEPS[3]
	assert_true(Tutorial.allows(cast, Tutorial.Action.CAST) and Tutorial.allows(cast, Tutorial.Action.SELECT_SPELL))
	assert_false(Tutorial.allows(cast, Tutorial.Action.END_TURN))
	assert_true(Tutorial.allows({}, Tutorial.Action.END_TURN), "no step: everything goes")


# --- The overlay ---

func test_the_overlay_dims_everything_but_the_hole_and_the_hole_stays_open() -> void:
	var overlay := TutorialOverlay.new()
	_tree().root.add_child(overlay)
	overlay.show_step("Hello", Rect2(300, 200, 200, 100))
	var screen := overlay.get_viewport_rect()
	var dims := overlay._dims
	var covered := 0.0
	for dim in dims:
		assert_false(Rect2(dim.position, dim.size).intersects(overlay.hole), "a dim rectangle never covers the hole")
		assert_eq(dim.mouse_filter, Control.MOUSE_FILTER_STOP, "and swallows the mouse")
		covered += dim.size.x * dim.size.y
	assert_true(absf(covered + overlay.hole.size.x * overlay.hole.size.y - screen.size.x * screen.size.y) < 1.0, "dims plus hole make the whole screen")
	assert_true(overlay.hole.encloses(Rect2(300, 200, 200, 100)), "the hole holds the area (with padding)")
	overlay.set_hole(Rect2(10, 10, 50, 50))
	assert_true(overlay.hole.position.x >= 0.0 and overlay.hole.position.y >= 0.0, "kept on screen")
	overlay.clear()
	assert_false(overlay.is_active())
	overlay.free()


func test_the_overlays_card_stays_on_screen() -> void:
	var overlay := TutorialOverlay.new()
	_tree().root.add_child(overlay)
	var screen := overlay.get_viewport_rect()
	for area in [Rect2(0, 0, 60, 40), Rect2(screen.size.x - 80, screen.size.y - 60, 80, 60), Rect2(500, 300, 100, 100)]:
		overlay.show_step("A card with a text long enough to wrap onto a second line or two.", area)
		var card := overlay._card
		assert_true(Rect2(Vector2.ZERO, screen.size).encloses(Rect2(card.position, card.size)), "card on screen for %s: %s %s" % [area, card.position, card.size])
	overlay.free()


# --- The battle's steps ---

func test_the_first_battle_walks_the_player_through_ready_move_spell_cast_end_turn() -> void:
	var settings := Settings.new()
	var tutorial := Tutorial.new(settings)
	var controller := _controller(tutorial)
	assert_eq(_step_id(controller), "ready", "the first step")
	assert_true(controller.hud.is_tutorial_active())
	# Nothing but Ready works yet.
	controller.click_cell(Vector2i(1, 0))
	controller.select_spell(0)
	assert_eq([controller.input_state, controller.selected_spell], [BattleController.State.PLACING, -1])
	var changes := [0]
	controller.tutorial_changed.connect(func() -> void: changes[0] += 1)
	controller.end_turn()  # Ready.
	assert_true(await _wait_state(controller, BattleController.State.IDLE))
	assert_eq(_step_id(controller), "move", "then walking")
	assert_true(changes[0] >= 1, "progress is reported (the Game root saves it)")
	controller.select_spell(0)
	controller.end_turn()
	assert_eq([controller.input_state, controller.battle.state.current_unit().id], [BattleController.State.IDLE, 0], "spells and End turn wait")
	var enemy_cell := Vector2i(3, 0)
	controller.click_cell(enemy_cell)  # Not reachable: nothing.
	assert_eq(_step_id(controller), "move")
	controller.click_cell(Vector2i(1, 0))  # A blue cell.
	assert_true(await _wait_state(controller, BattleController.State.IDLE))
	assert_eq(_step_id(controller), "spell")
	controller.click_cell(Vector2i(0, 0))  # Walking is over for the tutorial's sake: no more moves.
	assert_eq(controller.battle.state.units[0].cell, Vector2i(1, 0), "the walk stays done")
	controller.end_turn()
	assert_eq(controller.input_state, BattleController.State.IDLE, "End turn waits")
	controller.select_spell(0)
	assert_eq([controller.input_state, _step_id(controller)], [BattleController.State.TARGETING, "cast"])
	controller.end_turn()
	assert_eq(controller.input_state, BattleController.State.TARGETING, "End turn still waits")
	controller.click_cell(Vector2i(3, 0))
	assert_true(await _wait_state(controller, BattleController.State.IDLE))
	assert_eq(_step_id(controller), "end_turn")
	controller.select_spell(0)
	assert_eq(controller.input_state, BattleController.State.IDLE, "only End turn goes through")
	controller.end_turn()
	assert_true(await _wait_state(controller, BattleController.State.IDLE))
	assert_eq(_step_id(controller), "", "the tutorial is over")
	assert_false(controller.hud.is_tutorial_active())
	controller.select_spell(0)
	assert_eq(controller.input_state, BattleController.State.TARGETING, "everything works now")
	for step in Tutorial.BATTLE_STEPS:
		assert_true(tutorial.is_done(step["id"]), "%s done" % step["id"])
	assert_true(settings.dismissed_hints.has("tutorial_end_turn"), "and kept in the settings")
	controller.free()


func test_skipping_ends_the_tutorial_at_once_and_everything_works() -> void:
	var tutorial := Tutorial.new(Settings.new())
	var controller := _controller(tutorial)
	var changes := [0]
	controller.tutorial_changed.connect(func() -> void: changes[0] += 1)
	controller.hud.tutorial_skipped.emit()
	assert_false(controller.hud.is_tutorial_active())
	assert_eq(changes[0], 1)
	controller.end_turn()
	assert_true(await _wait_state(controller, BattleController.State.IDLE))
	assert_eq(_step_id(controller), "")
	controller.select_spell(0)
	assert_eq(controller.input_state, BattleController.State.TARGETING)
	controller.free()


func test_a_step_that_cannot_apply_is_skipped_as_done() -> void:
	var tutorial := Tutorial.new(Settings.new())
	var controller := _controller(tutorial, 0)  # A hero with no MP: nothing to walk to.
	controller.end_turn()
	assert_true(await _wait_state(controller, BattleController.State.IDLE))
	assert_true(tutorial.is_done("move"), "the walking step is done without a walk")
	assert_eq(_step_id(controller), "spell", "on to the spells")
	controller.free()


func test_a_board_spotlight_follows_the_cells_and_the_camera() -> void:
	var tutorial := Tutorial.new(Settings.new())
	var controller := _controller(tutorial)
	controller.end_turn()
	assert_true(await _wait_state(controller, BattleController.State.IDLE))
	assert_eq(_step_id(controller), "move")
	var before := controller.hud._tutorial.hole
	assert_true(before.has_area(), "a hole around the blue cells")
	controller.camera_rig.rotate_steps(1, false)
	for i in 90:  # The camera glides to the hero's turn too; let it settle.
		await _tree().process_frame
	assert_ne(controller.hud._tutorial.hole, before, "the spotlight moved with the camera")
	var reach: Array[Vector2i] = controller._reach.cells()
	var rect := controller._screen_rect_of(reach)
	var hole: Rect2 = controller.hud._tutorial.hole
	assert_true(hole.grow(1.0).encloses(rect.intersection(controller.hud._tutorial.get_viewport_rect())), "and still holds every walkable cell: %s vs %s" % [hole, rect])
	controller.free()


func test_a_battle_without_a_tutorial_is_unchanged() -> void:
	var controller := _controller(null)
	assert_false(controller.hud.is_tutorial_active())
	controller.end_turn()
	assert_true(await _wait_state(controller, BattleController.State.IDLE))
	controller.select_spell(0)
	assert_eq(controller.input_state, BattleController.State.TARGETING)
	controller.free()


# --- The starter rune and the hub's rune step ---

func test_the_first_victory_always_brings_the_starter_rune_once() -> void:
	var roster := load("res://data/progression/roster.tres") as Roster
	var tower := load("res://data/tower/tower.tres") as TowerConfig
	assert_true(roster.config.first_rune != null, "the shipped config names a starter rune")
	var profile := Profile.create(roster)
	assert_false(profile.starter_rune_given)
	RunDirector.start_tower(profile, tower, 1)
	var report := RunDirector.apply_result(profile, tower, _won_battle(profile, tower))
	assert_true(report.won)
	assert_true(profile.stash.has(roster.config.first_rune), "the rune is in the stash")
	assert_true(report.rewards.runes.has(roster.config.first_rune), "and listed among the finds")
	assert_true(profile.starter_rune_given)
	# With a starter rune no loot table can drop, a second win must not bring it again.
	var unique := RuneData.new()
	unique.display_name = "Starter only"
	var config := roster.config.duplicate() as ProgressionConfig
	config.first_rune = unique
	var own_roster := roster.duplicate() as Roster
	own_roster.config = config
	var fresh := Profile.create(own_roster)
	RunDirector.start_tower(fresh, tower, 1)
	var first := RunDirector.apply_result(fresh, tower, _won_battle(fresh, tower))
	assert_true(first.rewards.runes.has(unique) and fresh.stash.has(unique), "the first win gives it")
	var second := RunDirector.apply_result(fresh, tower, _won_battle(fresh, tower))
	assert_false(second.rewards.runes.has(unique), "the second win does not")
	assert_eq(fresh.stash.filter(func(r: RuneData) -> bool: return r == unique).size(), 1, "exactly one in the stash")
	var restored := Profile.from_dict(profile.to_dict(), roster)
	assert_true(restored.starter_rune_given, "kept in the save")


func _won_battle(profile: Profile, tower: TowerConfig) -> BattleState:
	var setup := RunDirector.battle_setup(profile, tower)
	var builds := setup.encounter.builds()
	var enemies: Array[UnitData] = []
	for build in builds:
		enemies.append(build.unit)
	var state := BattleState.create(setup.encounter.map.parse(), setup.units, enemies, 1, setup.modifiers, builds, setup.hero_hp)
	for unit in state.units:
		if unit.team == UnitState.Team.ENEMY:
			unit.hp = 0
	return state


func _lost_battle(profile: Profile, tower: TowerConfig) -> BattleState:
	var state := _won_battle(profile, tower)
	for unit in state.units:
		unit.hp = 0 if unit.team == UnitState.Team.PLAYER else unit.max_hp()
	return state


func test_a_lost_first_battle_gives_no_starter_rune() -> void:
	var roster := load("res://data/progression/roster.tres") as Roster
	var tower := load("res://data/tower/tower.tres") as TowerConfig
	var profile := Profile.create(roster)
	RunDirector.start_tower(profile, tower, 1)
	var report := RunDirector.apply_result(profile, tower, _lost_battle(profile, tower))
	assert_false(report.won)
	assert_false(profile.starter_rune_given)
	assert_true(profile.stash.is_empty())


func _party(profile: Profile, tutorial: Tutorial) -> PartyScreen:
	var screen := (load("res://scenes/game/party_screen.tscn") as PackedScene).instantiate() as PartyScreen
	screen.tutorial = tutorial
	_tree().root.add_child(screen)
	screen.show_profile(profile, "", "", load("res://data/tower/tower.tres") as TowerConfig)
	return screen


func test_the_hub_lights_the_stash_when_it_holds_a_rune_and_waits_for_the_equip() -> void:
	var roster := load("res://data/progression/roster.tres") as Roster
	var tutorial := Tutorial.new(Settings.new())
	var profile := Profile.create(roster)
	var empty := _party(profile, tutorial)
	assert_false(empty._tutorial_overlay.is_active(), "no rune yet: nothing to teach")
	empty.free()
	profile.stash.append(roster.config.first_rune)
	var screen := _party(profile, tutorial)
	assert_true(screen._tutorial_overlay.is_active(), "a rune in the stash: the equip step")
	await _tree().process_frame
	await _tree().process_frame
	assert_true(screen._tutorial_overlay.hole.encloses(screen._stash.get_global_rect()), "lighting the stash")
	var changes := [0]
	screen.tutorial_changed.connect(func() -> void: changes[0] += 1)
	var equips := []
	screen.equip_requested.connect(func(hero: int, index: int) -> void: equips.append([hero, index]))
	screen._stash.equip_requested.emit(0)
	assert_eq(equips.size(), 1, "the equip goes through")
	assert_false(screen._tutorial_overlay.is_active(), "and ends the step")
	assert_true(tutorial.is_done("equip"))
	assert_eq(changes[0], 1)
	screen.free()
	var again := _party(profile, tutorial)
	assert_false(again._tutorial_overlay.is_active(), "done once, never again")
	again.free()


func test_skipping_in_the_hub_ends_the_step_and_esc_is_blocked_while_it_shows() -> void:
	var roster := load("res://data/progression/roster.tres") as Roster
	var tutorial := Tutorial.new(Settings.new())
	var profile := Profile.create(roster)
	profile.stash.append(roster.config.first_rune)
	var screen := _party(profile, tutorial)
	assert_true(screen._tutorial_overlay.block_cancel, "Esc can't leave the hub mid-step")
	screen._tutorial_overlay.skipped.emit()
	assert_false(screen._tutorial_overlay.is_active())
	assert_true(tutorial.is_done("equip") and tutorial.is_done("ready"), "skip marks everything done")
	screen.free()


# --- Tips and tooltips ---

func test_the_glossary_explains_every_term_and_the_cards_carry_it() -> void:
	for key in [&"hp", &"ap", &"mp", &"power", &"resistance", &"initiative"]:
		assert_true(Glossary.tip(key).length() > 20, "%s is explained" % key)
	var card := (load("res://scenes/battle/hud/unit_card.tscn") as PackedScene).instantiate() as UnitCard
	_tree().root.add_child(card)
	var unit := UnitState.new(0, BattleFixtures.unit("P0", 100, 3, 6, 20), UnitState.Team.PLAYER, Vector2i.ZERO)
	card.show_unit(UnitInfo.from_unit(unit))
	assert_eq(card.get_node("%ApLabel").tooltip_text, Glossary.tip(&"ap"))
	assert_eq(card.get_node("%MpLabel").tooltip_text, Glossary.tip(&"mp"))
	assert_true(card.get_node("%CombatStats").tooltip_text.contains(Glossary.tip(&"power")))
	assert_eq((card.get_node("%ApLabel") as Control).mouse_filter, Control.MOUSE_FILTER_PASS, "tooltips need the mouse")
	card.free()


func test_a_status_applied_shows_its_one_time_tip_and_dismissing_it_is_remembered() -> void:
	var settings := Settings.new()
	var hints := Hints.new(settings)
	var controller := _controller(null)
	controller.hints = hints
	var saves := [0]
	controller.tutorial_changed.connect(func() -> void: saves[0] += 1)
	var status := load("res://data/statuses/poison.tres") as StatusData
	controller._on_event_played(BattleEvents.StatusApplied.new(1, status, 3))
	assert_true((controller.hud.get_node("%HintCard") as Control).visible, "the tip shows")
	(controller.hud.get_node("%HintCard").get_node("%DismissButton") as Button).pressed.emit()
	assert_false(hints.should_show("first_status"), "and is not shown again")
	assert_eq(saves[0], 1, "the dismissal is reported to be saved")
	controller._on_event_played(BattleEvents.StatusApplied.new(1, status, 3))
	assert_false((controller.hud.get_node("%HintCard") as Control).visible, "never twice")
	controller.free()


func test_no_tip_competes_with_a_tutorial_step() -> void:
	var controller := _controller(Tutorial.new(Settings.new()))
	controller.hints = Hints.new(Settings.new())
	controller._show_tip("first_status")
	assert_false((controller.hud.get_node("%HintCard") as Control).visible, "the step is up: the tip waits")
	controller.free()


func test_elite_and_boss_floors_open_with_their_tip_and_a_level_up_shows_its_own() -> void:
	var game := (load("res://scenes/game/game.tscn") as PackedScene).instantiate() as Game
	game.play_opens_multiplayer = false  # These tests use the single-player hub.
	game.save_path = "user://test_tutorial/profile.json"
	game.settings_path = "user://test_tutorial/settings.cfg"
	DirAccess.make_dir_recursive_absolute("user://test_tutorial")
	_tree().root.add_child(game)
	RunDirector.start_tower(game.profile, game.tower, 1)
	game.profile.run.floor_number = 5
	assert_eq(game._opening_tip(), "first_elite")
	game.profile.run.floor_number = 10
	assert_eq(game._opening_tip(), "first_boss")
	game.profile.run.floor_number = 4
	assert_eq(game._opening_tip(), "")
	var report := RunDirector.Report.new()
	report.rewards = BattleRewards.new()
	report.level_ups = [Profile.LevelUp.new(0, 1, 2)] as Array[Profile.LevelUp]
	game._show_run_screen(report, "Floor 1 cleared")
	assert_true((game.screen.get_node("%HintCard") as Control).visible, "the level-up tip")
	game.free()
	for file in ["profile.json", "settings.cfg"]:
		DirAccess.remove_absolute("user://test_tutorial/%s" % file)
	DirAccess.remove_absolute("user://test_tutorial")


func test_the_card_never_covers_the_spotlight_when_there_is_room_beside_it() -> void:
	var overlay := TutorialOverlay.new()
	_tree().root.add_child(overlay)
	var screen := overlay.get_viewport_rect()
	# A tall hole taking the whole height: below and above don't fit, the sides do.
	overlay.show_step("A card with a text long enough to wrap onto a second line or two.", Rect2(400, 0, 300, screen.size.y))
	var card := Rect2(overlay._card.position, overlay._card.size)
	assert_false(card.intersects(overlay.hole), "beside the hole, not over it: card %s hole %s" % [card, overlay.hole])
	assert_true(Rect2(Vector2.ZERO, screen.size).encloses(card))
	assert_eq(overlay._card.mouse_filter, Control.MOUSE_FILTER_IGNORE, "the card doesn't take the mouse")
	assert_eq(overlay._skip.mouse_filter, Control.MOUSE_FILTER_STOP, "only the Skip button does")
	overlay.free()


func test_a_tutorial_step_hides_a_tip_card_and_the_start_screen_ignores_escape_and_modifiers() -> void:
	var controller := _controller(Tutorial.new(Settings.new()))
	controller.hud.show_hint("A tip")
	controller.hud.show_tutorial_step("Step", Rect2(100, 100, 100, 100))
	assert_false((controller.hud.get_node("%HintCard") as Control).visible, "the tip waits")
	controller.free()
	var screen := (load("res://scenes/game/start_screen.tscn") as PackedScene).instantiate() as StartScreen
	_tree().root.add_child(screen)
	var starts := [0]
	screen.started.connect(func() -> void: starts[0] += 1)
	for code in [KEY_ESCAPE, KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]:
		var key := InputEventKey.new()
		key.keycode = code
		key.pressed = true
		screen._unhandled_input(key)
	assert_eq(starts[0], 0, "no gesture for the browser")
	screen.free()


func test_a_stage_opens_with_its_own_tip_not_the_boss_floor_one() -> void:
	var game := (load("res://scenes/game/game.tscn") as PackedScene).instantiate() as Game
	game.play_opens_multiplayer = false  # These tests use the single-player hub.
	game.save_path = "user://test_tutorial/profile.json"
	game.settings_path = "user://test_tutorial/settings.cfg"
	DirAccess.make_dir_recursive_absolute("user://test_tutorial")
	_tree().root.add_child(game)
	game.profile.best_depth = 10
	RunDirector.start_stage(game.profile, game.tower, game.tower.stages[0])
	assert_eq(game._opening_tip(), "first_stage")
	assert_false(Hints.TEXTS["first_stage"].contains("boon"), "no word of boons: a stage offers none")
	game.free()
	for file in ["profile.json", "settings.cfg"]:
		DirAccess.remove_absolute("user://test_tutorial/%s" % file)
	DirAccess.remove_absolute("user://test_tutorial")
