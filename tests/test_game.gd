extends TestCase
## The game root: the hub, tower and stage runs through the director, the run screen
## between floors, boss choices, saving and resuming.

const GAME_SCENE := preload("res://scenes/game/game.tscn")
const SAVE := "user://test_game/profile.json"
const SETTINGS := "user://test_game/settings.cfg"


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func _game() -> Game:
	DirAccess.make_dir_recursive_absolute(SAVE.get_base_dir())
	SaveStore.new(SAVE).delete()
	SettingsStore.new(SETTINGS).delete()
	return _open()


func _open() -> Game:
	var game := GAME_SCENE.instantiate() as Game
	game.play_opens_multiplayer = false  # These tests use the single-player hub.
	game.save_path = SAVE
	game.settings_path = SETTINGS
	game.rng_seed = 5
	game.require_click_to_start = false  # Straight to the title.
	_tree().root.add_child(game)
	_press(game.screen, "PlayButton")  # Title → hub.
	return game


func after_each_clean() -> void:
	SaveStore.new(SAVE).delete()
	SettingsStore.new(SETTINGS).delete()
	DirAccess.remove_absolute(SAVE.get_base_dir())


func _saved(game: Game) -> Profile:
	return SaveStore.new(SAVE).load_or_create(game.roster)


func _press(screen: Node, button_name: String) -> void:
	(screen.find_child(button_name, true, false) as Button).pressed.emit()


func _battle(game: Game) -> BattleController:
	return game.screen as BattleController


## Ends the current battle, then closes its result screen ("Continue").
func _finish(game: Game, players_win: bool) -> BattleState:
	var battle := _battle(game)
	for unit in battle.battle.state.units:
		if (unit.team == UnitState.Team.ENEMY) == players_win:
			unit.hp = 0
	var state := battle.battle.state
	(battle.hud.get_node("%RestartButton") as Button).pressed.emit()
	return state


func _lines(game: Game) -> String:
	return (game.screen.get_node("%Lines") as Label).text


func test_the_game_opens_on_the_hub_with_the_three_heroes() -> void:
	var game := _game()
	assert_true(game.screen is PartyScreen)
	assert_eq(game.profile.party, [0, 1, 2] as Array[int])
	assert_true(game.screen.find_child("TowerButton", true, false) != null)
	var first := game.screen.find_child("Stage0", true, false) as Button
	assert_true(first.disabled, "the first stage waits for tower floor 10")
	assert_eq(first.tooltip_text, "Clear tower floor 10 first.")
	assert_true((game.screen.find_child("Stage1", true, false) as Button).disabled, "locked until stage 1 is cleared")
	assert_eq(game.screen.find_child("ContinueButton", true, false), null, "no run to continue")
	after_each_clean()

func test_the_tower_starts_a_run_at_floor_one() -> void:
	var game := _game()
	_press(game.screen, "TowerButton")
	var battle := _battle(game)
	assert_true(battle != null, "a battle")
	assert_false(battle.standalone)
	assert_eq(battle.battle_title, "Floor 1")
	assert_eq(battle.battle.state.units.filter(func(u: UnitState) -> bool: return u.team == UnitState.Team.PLAYER).size(), 3)
	assert_eq(battle.battle.sudden_death_round, game.tower.sudden_death_round)
	assert_true((battle.hud.get_node("%RoundLabel") as Label).text.begins_with("Floor 1 · Round"))
	assert_eq(_saved(game).run.floor_number, 1, "the run is saved as it starts")
	after_each_clean()

func test_a_won_floor_shows_the_run_screen_then_the_next_floor() -> void:
	var game := _game()
	game.start_tower(1)
	var state := _finish(game, true)
	var xp := BattleRewards.compute(state).xp
	assert_true(game.screen is RunScreen)
	assert_true(_lines(game).begins_with("+%d XP" % xp), _lines(game))
	assert_eq(game.profile.heroes[0].xp, xp)
	assert_eq(game.profile.run.floor_number, 2)
	assert_eq(_saved(game).run.floor_number, 2, "saved between floors")
	assert_eq(_saved(game).heroes[0].xp, xp)
	_press(game.screen, "NextButton")
	assert_eq(_battle(game).battle_title, "Floor 2")
	after_each_clean()

func test_heroes_start_the_next_floor_with_their_carried_hp() -> void:
	var game := _game()
	game.start_tower(1)
	_finish(game, true)
	game.profile.run.hero_hp[0] = 20
	game.next_step()
	assert_eq(_battle(game).battle.state.units[0].hp, 20)
	after_each_clean()

func test_a_lost_floor_ends_the_run() -> void:
	var game := _game()
	game.start_tower(1)
	_finish(game, false)
	assert_true(game.screen is RunScreen)
	assert_eq(game.profile.run, null)
	assert_eq(game.profile.heroes[0].xp, 0)
	assert_eq(_saved(game).run, null)
	_press(game.screen, "BackButton")
	assert_true(game.screen is PartyScreen)
	assert_true((game.screen.get_node("%Summary") as Label).text.begins_with("Defeat"))
	after_each_clean()

func test_a_saved_run_resumes_at_the_next_floor() -> void:
	var game := _game()
	game.start_tower(1)
	_finish(game, true)
	game.free()
	var reopened := _open()
	assert_true(reopened.screen is PartyScreen)
	assert_eq(reopened.screen.find_child("TowerButton", true, false), null, "no new run while one is saved")
	_press(reopened.screen, "ContinueButton")
	assert_eq(_battle(reopened).battle_title, "Floor 2")
	after_each_clean()

func test_a_run_can_be_abandoned() -> void:
	var game := _game()
	game.start_tower(1)
	_finish(game, true)
	game.show_party()
	_press(game.screen, "AbandonButton")
	assert_eq(game.profile.run, null)
	assert_eq(_saved(game).run, null)
	assert_true(game.screen.find_child("TowerButton", true, false) != null)
	after_each_clean()

func test_a_boss_gives_a_boon_then_the_climb_goes_on() -> void:
	var game := _game()
	game.profile.cleared_stages.append(game.tower.stages[0])  # The cap goes up to floor 20.
	game.start_tower(1)
	game.profile.run.floor_number = 10
	game.next_step()
	_finish(game, true)
	assert_true(game.profile.run.awaiting_choice())
	var go_on := game.screen.find_child("ContinueButton", true, false) as Button
	assert_true(go_on.disabled, "a choice comes first")
	_press(game.screen, "Boon0")
	assert_false(go_on.disabled)
	var boon := game.profile.run.boss_offer[0]
	go_on.pressed.emit()
	assert_eq(game.profile.run.boons, [boon] as Array[BoonData])
	assert_eq(_battle(game).battle_title, "Floor 11")
	assert_eq(_saved(game).run.boons.size(), 1)
	after_each_clean()

func test_a_pending_boss_choice_survives_a_restart_and_leaving_ends_the_run() -> void:
	var game := _game()
	game.profile.cleared_stages.append(game.tower.stages[0])
	game.start_tower(1)
	game.profile.run.floor_number = 10
	game.next_step()
	_finish(game, true)
	game.free()
	var reopened := _open()
	_press(reopened.screen, "ContinueButton")
	assert_true(reopened.screen is RunScreen, "back to the boss choice")
	_press(reopened.screen, "Heal")
	_press(reopened.screen, "LeaveButton")
	assert_eq(reopened.profile.run, null)
	assert_true(_lines(reopened).contains("leave the tower after floor 10"), _lines(reopened))
	_press(reopened.screen, "BackButton")
	assert_true(reopened.screen is PartyScreen)
	assert_eq(reopened.profile.best_depth, 10)
	after_each_clean()

func test_a_cleared_stage_unlocks_the_next_one() -> void:
	var game := _game()
	game.profile.best_depth = 10  # The first ten floors cleared.
	game.show_party()
	_press(game.screen, "Stage0")
	assert_eq(_battle(game).battle_title, game.tower.stages[0].display_name)
	_finish(game, true)
	assert_eq(game.profile.run, null, "a stage is one battle")
	assert_eq(game.profile.cleared_stages, [game.tower.stages[0]] as Array[StageData])
	_press(game.screen, "BackButton")
	assert_false((game.screen.find_child("Stage1", true, false) as Button).disabled)
	var floors := game.screen.find_child("StartFloor", true, false) as OptionButton
	assert_eq(floors.item_count, 2, "floors 1 and 11")
	after_each_clean()

func test_a_locked_stage_cant_be_started() -> void:
	var game := _game()
	game.start_stage(1)
	assert_true(game.screen is PartyScreen)
	assert_eq(game.profile.run, null)
	assert_true((game.screen.get_node("%Summary") as Label).text.contains("previous stage"))
	after_each_clean()

func test_results_are_saved_as_soon_as_the_battle_ends() -> void:
	var game := _game()
	game.start_tower(1)
	var battle := _battle(game)
	assert_eq(battle.input_state, BattleController.State.PLACING, "a floor opens on placement")
	battle.end_turn()  # Ready.
	for unit in battle.battle.state.units:
		if unit.team == UnitState.Team.ENEMY:
			unit.hp = 0
	battle._begin_next()  # The battle notices it's over and shows the result screen.
	assert_eq(battle.input_state, BattleController.State.ENDED)
	var xp := game.profile.heroes[0].xp
	assert_true(xp > 0, "applied before Continue")
	assert_eq(_saved(game).heroes[0].xp, xp, "already saved")
	battle.battle_finished.emit(battle.battle.state)
	assert_eq(game.profile.heroes[0].xp, xp, "not rewarded twice")
	assert_eq(game.profile.run.floor_number, 2, "not advanced twice")
	after_each_clean()

func test_equip_requests_go_through_the_game_and_save() -> void:
	var game := _game()
	game.profile.stash = [load("res://data/runes/might.tres")] as Array[RuneData]
	var party := game.screen as PartyScreen
	party.equip_requested.emit(0, 0)
	assert_eq(game.profile.heroes[0].runes[0].display_name, "Rune of Might")
	assert_eq(_saved(game).heroes[0].runes[0].display_name, "Rune of Might")
	party.unequip_requested.emit(0, 0)
	assert_eq(game.profile.stash.size(), 1)
	party.unequip_requested.emit(0, 0)
	assert_true((party.get_node("%Summary") as Label).text.contains("empty"), "errors are shown")
	assert_true(party.find_child("TowerButton", true, false) != null, "the hub stays")
	after_each_clean()

func test_the_standalone_battle_scene_still_plays_again() -> void:
	var battle := (load("res://scenes/battle/battle.tscn") as PackedScene).instantiate() as BattleController
	battle.rng_seed = 3
	_tree().root.add_child(battle)
	assert_true(battle.standalone)
	assert_eq((battle.hud.get_node("%RestartButton") as Button).text, "Play again")
	var first := battle.battle
	(battle.hud.get_node("%RestartButton") as Button).pressed.emit()
	assert_ne(battle.battle, first, "a new battle")
	after_each_clean()


func test_an_invalid_tower_keeps_the_hub_with_its_errors() -> void:
	var game := _game()
	game.tower = TowerConfig.new()
	game.start_tower(1)
	assert_true(game.screen is PartyScreen)
	assert_true((game.screen.get_node("%Summary") as Label).text.contains("The tower is invalid"))
	assert_eq(game.profile.run, null)
	after_each_clean()


func test_the_game_opens_on_the_title_and_play_opens_the_hub() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE.get_base_dir())
	SaveStore.new(SAVE).delete()
	var game := GAME_SCENE.instantiate() as Game
	game.play_opens_multiplayer = false  # These tests use the single-player hub.
	game.require_click_to_start = false  # Straight to the title.
	game.save_path = SAVE
	game.settings_path = SETTINGS
	_tree().root.add_child(game)
	assert_true(game.screen is TitleScreen, "the title first")
	assert_eq((game.screen.get_node("%TitleLabel") as Label).text, Game.TITLE)
	assert_true((game.screen.get_node("%QuitButton") as Button).visible or OS.has_feature("web"))
	_press(game.screen, "PlayButton")
	assert_true(game.screen is PartyScreen, "Play opens the hub")
	game.free()


func test_esc_on_the_hub_goes_back_to_the_title_but_not_from_the_title() -> void:
	var game := _game()
	assert_true(game.screen is PartyScreen)
	var escape := InputEventAction.new()
	escape.action = &"ui_cancel"
	escape.pressed = true
	(game.screen as Screen)._unhandled_input(escape)
	assert_true(game.screen is TitleScreen, "hub → title")
	(game.screen as Screen)._unhandled_input(escape)
	assert_true(game.screen is TitleScreen, "the title has no back")
	game.free()


func test_a_saved_run_waits_on_the_hub_after_the_title() -> void:
	var game := _game()
	_press(game.screen, "TowerButton")
	game.free()
	var reopened := _open()
	assert_true(reopened.screen is PartyScreen, "the hub, not straight into the run")
	assert_true(reopened.screen.find_child("ContinueButton", true, false) != null, "with Continue run")
	reopened.free()


func test_settings_open_from_the_title_save_on_change_and_go_back() -> void:
	var game := _game()
	var escape := InputEventAction.new()
	escape.action = &"ui_cancel"
	escape.pressed = true
	(game.screen as Screen)._unhandled_input(escape)  # Hub → title.
	_press(game.screen, "SettingsButton")
	assert_true(game.screen is SettingsScreen)
	(game.screen.get_node("%UiScale") as OptionButton).item_selected.emit(3)
	assert_eq(game.get_window().content_scale_factor, 1.5, "applied at once")
	assert_eq(SettingsStore.new(SETTINGS).load_or_default().ui_scale, 1.5, "and saved")
	_press(game.screen, "BackButton")
	assert_true(game.screen is TitleScreen)
	game.get_window().content_scale_factor = 1.0
	game.free()


func test_resetting_the_save_keeps_the_settings() -> void:
	var game := _game()
	game.profile.heroes[0].level = 5
	game.settings.ui_scale = 1.25
	game._on_settings_changed()
	game.show_settings()
	(game.screen.get_node("%ResetSaveButton") as Button).pressed.emit()
	(game.screen.get_node("%ConfirmYesButton") as Button).pressed.emit()
	assert_eq(game.profile.heroes[0].level, 1, "a fresh profile")
	assert_eq(_saved(game).heroes[0].level, 1, "saved")
	assert_eq(SettingsStore.new(SETTINGS).load_or_default().ui_scale, 1.25, "settings untouched")
	game.get_window().content_scale_factor = 1.0
	game.free()


func test_the_selected_hero_is_kept_across_screens() -> void:
	var game := _game()
	(game.screen.find_child("Hero1", true, false) as Button).pressed.emit()
	(game.screen as Screen).back_pressed.emit()  # Title.
	_press(game.screen, "PlayButton")
	assert_eq((game.screen as PartyScreen).selected_hero, 1)
	game.free()


func _hub_hint(game: Game) -> Control:
	return game.screen.get_node("%HintCard") as Control


func test_the_rune_step_waits_for_a_first_rune_and_holds_the_hub_hint_back() -> void:
	var game := _game()  # Reset hints, stash holding a rune, nothing equipped yet.
	game.profile.stash.append(load("res://data/runes/vitality.tres") as RuneData)
	game.show_party()
	assert_true((game.screen as PartyScreen).has_tutorial_step(), "the stash is lit")
	assert_false(_hub_hint(game).visible, "the tip waits for the next visit")
	game.profile.heroes[0].runes[0] = load("res://data/runes/vitality.tres") as RuneData
	game.show_party()
	assert_false((game.screen as PartyScreen).has_tutorial_step(), "a hero already wears a rune")
	assert_true(_hub_hint(game).visible, "so the tip shows")
	game.free()


func test_the_hub_hint_shows_once_and_its_dismissal_is_saved() -> void:
	var game := _game()
	assert_true(_hub_hint(game).visible, "first visit")
	(_hub_hint(game).get_node("%DismissButton") as Button).pressed.emit()
	assert_true(SettingsStore.new(SETTINGS).load_or_default().dismissed_hints.has("hub_intro"), "saved")
	game.show_party()
	assert_false(_hub_hint(game).visible, "not again")
	game.free()
	var reopened := _open()
	assert_false(_hub_hint(reopened).visible, "not after a restart either")
	reopened.free()


func test_show_hints_again_brings_the_hub_hint_back() -> void:
	var game := _game()
	(_hub_hint(game).get_node("%DismissButton") as Button).pressed.emit()
	game.show_settings()
	(game.screen.get_node("%ShowHintsButton") as Button).pressed.emit()
	game.show_party()
	assert_true(_hub_hint(game).visible)
	game.free()


func test_the_first_battle_opens_with_the_tutorial_and_skipping_is_saved() -> void:
	var game := _game()
	game.start_tower(1)
	var battle := _battle(game)
	assert_true(battle.hud.is_tutorial_active(), "the first battle opens with the first step")
	battle.hud.get_node("Root").find_child("SkipButton", true, false).pressed.emit()
	assert_false(battle.hud.is_tutorial_active())
	assert_true(game.tutorial.is_done("end_turn"), "every step is done")
	assert_true(SettingsStore.new(SETTINGS).load_or_default().dismissed_hints.has("tutorial_ready"), "and saved")
	game.start_tower(1)
	assert_false(_battle(game).hud.is_tutorial_active(), "not in the next battle")
	game.free()



func test_resetting_the_save_forgets_the_selected_hero() -> void:
	var game := _game()
	(game.screen.find_child("Hero1", true, false) as Button).pressed.emit()
	game.show_settings()
	(game.screen.get_node("%ResetSaveButton") as Button).pressed.emit()
	(game.screen.get_node("%ConfirmYesButton") as Button).pressed.emit()
	game.show_party()
	assert_eq((game.screen as PartyScreen).selected_hero, 0)
	game.free()


func test_runes_can_be_changed_between_floors_through_the_party_button() -> void:
	var game := _game()
	game.start_tower(1)
	_finish(game, true)
	assert_true(game.screen is RunScreen)
	_press(game.screen, "PartyButton")
	assert_true(game.screen is PartyScreen, "the hub between floors")
	assert_true(game.screen.find_child("ContinueButton", true, false) != null, "with the run waiting")
	game.profile.stash.append(load("res://data/runes/vitality.tres") as RuneData)
	var floor_before := game.profile.run.floor_number
	game._on_equip_requested(0, game.profile.stash.size() - 1)
	assert_true(game.profile.heroes[0].runes.has(load("res://data/runes/vitality.tres")), "equipped")
	_press(game.screen, "ContinueButton")
	assert_eq(_battle(game).battle_title, "Floor %d" % floor_before, "the run goes on where it was")
	game.free()


func test_hp_stays_when_a_rune_raises_the_maximum_and_a_lower_maximum_takes_the_excess_for_good() -> void:
	var game := _game()
	game.start_tower(1)
	_finish(game, true)
	var vitality := load("res://data/runes/vitality.tres") as RuneData
	game.profile.stash.append(vitality)
	game.show_party()
	game.profile.run.hero_hp[0] = 30
	game._on_equip_requested(0, game.profile.stash.size() - 1)
	assert_eq(game.profile.run.hero_hp[0], 30, "no heal from the bigger maximum")
	game.profile.run.hero_hp[0] = RunDirector.max_hp(game.profile, 0)
	var slot := game.profile.heroes[0].runes.find(vitality)
	game._on_unequip_requested(0, slot)
	var lowered := game.profile.run.hero_hp[0]
	assert_eq(lowered, RunDirector.max_hp(game.profile, 0), "capped to the smaller maximum")
	game._on_equip_requested(0, game.profile.stash.size() - 1)
	assert_eq(game.profile.run.hero_hp[0], lowered, "re-equipping doesn't bring the excess back")
	game.free()


func test_rune_requests_are_ignored_during_a_fight() -> void:
	var game := _game()
	game.profile.stash.append(load("res://data/runes/vitality.tres") as RuneData)
	game.start_tower(1)
	assert_true(game.screen is BattleController)
	game._on_equip_requested(0, 0)
	assert_eq(game.profile.stash.size(), 1, "the rune stayed in the stash: no swapping mid-fight")
	game._on_unequip_requested(0, 0)
	assert_eq(game.profile.stash.size(), 1)
	game.free()


func test_a_full_hp_hero_gets_no_free_heal_from_a_bigger_maximum() -> void:
	var game := _game()
	game.start_tower(1)
	game.profile.run.hero_hp[0] = -1  # "Full", as after a boss heal.
	var before := RunDirector.max_hp(game.profile, 0)
	game.show_party()
	game.profile.stash.append(load("res://data/runes/vitality.tres") as RuneData)
	game._on_equip_requested(0, game.profile.stash.size() - 1)
	assert_eq(game.profile.run.hero_hp[0], before, "still the old maximum, not the new one")
	game.free()


func test_runes_can_change_while_a_boss_choice_is_pending_and_the_run_returns_to_it() -> void:
	var game := _game()
	game.profile.cleared_stages.append(game.tower.stages[0])
	game.start_tower(1)
	game.profile.run.floor_number = 10
	game.next_step()
	_finish(game, true)
	assert_true(game.profile.run.awaiting_choice())
	_press(game.screen, "PartyButton")
	game.profile.stash.append(load("res://data/runes/vitality.tres") as RuneData)
	game._on_equip_requested(0, game.profile.stash.size() - 1)
	_press(game.screen, "ContinueButton")
	assert_true(game.screen is RunScreen, "back to the boss choice")
	assert_true(game.profile.run.awaiting_choice(), "still pending")
	game.free()


func test_leaving_a_fight_returns_to_the_hub_with_the_run_and_no_rewards() -> void:
	var game := _game()
	game.start_tower(1)
	var battle := _battle(game)
	assert_true((battle.hud.get_node("%MenuButton") as Control).visible, "offered in a run")
	var xp_before := game.profile.heroes[0].xp
	var hp_before := game.profile.run.hero_hp.duplicate()
	(battle.hud.get_node("%MenuButton") as Button).pressed.emit()
	(battle.hud.get_node("%LeaveButton") as Button).pressed.emit()
	assert_true(game.screen is PartyScreen, "back on the hub")
	assert_true(game.profile.run != null and game.profile.run.floor_number == 1, "the run waits at the same floor")
	assert_eq(game.profile.heroes[0].xp, xp_before, "no rewards")
	assert_eq(game.profile.run.hero_hp, hp_before, "HP as before the fight")
	assert_true((game.screen.get_node("%Summary") as Label).text.contains("left the fight"))
	assert_true(game.screen.find_child("ContinueButton", true, false) != null)
	_press(game.screen, "ContinueButton")
	assert_true(game.screen is BattleController, "continuing starts the floor over")
	game.free()


func test_salvaging_a_rune_is_saved_and_ignored_during_a_fight() -> void:
	var game := _game()
	game.profile.stash.append(load("res://data/runes/might.tres") as RuneData)
	game.profile.stash.append(load("res://data/runes/focus.tres") as RuneData)
	game.show_party()
	(game.screen.find_child("Salvage0", true, false) as Button).pressed.emit()
	(game.screen.find_child("SalvageYes0", true, false) as Button).pressed.emit()
	assert_eq(game.profile.stash.size(), 1, "gone")
	assert_eq(_saved(game).stash.size(), 1, "and saved")
	assert_true(game.screen is PartyScreen, "still on the hub")
	game.start_tower(1)
	game._on_salvage_requested(0)
	assert_eq(game.profile.stash.size(), 1, "never during a fight")
	game.free()


func test_salvaging_and_fusing_runes_change_the_essence_and_are_saved() -> void:
	var game := _game()
	var might := load("res://data/runes/might.tres") as RuneData
	for i in 4:
		game.profile.stash.append(might)
	game.show_party()
	game._on_salvage_requested(3)
	assert_eq(game.profile.essence, might.salvage_value())
	game.profile.essence = might.fuse_cost()
	game._on_fuse_requested(0)
	assert_eq(game.profile.stash.size(), 1)
	assert_eq(game.profile.stash[0].level, 2)
	assert_eq(game.profile.essence, 0)
	var saved := _saved(game)
	assert_eq([saved.stash.size(), saved.stash[0].level, saved.essence], [1, 2, 0], "all saved")
	game.free()


func test_salvaging_by_clicking_removes_exactly_the_clicked_rune() -> void:
	var game := _game()
	var might := load("res://data/runes/might.tres") as RuneData
	var third := RuneData.leveled(might, 3)
	game.profile.stash.assign([might, third, might, third])
	game.show_party()
	(game.screen.find_child("Salvage3", true, false) as Button).pressed.emit()
	(game.screen.find_child("SalvageYes3", true, false) as Button).pressed.emit()
	assert_eq(game.profile.stash.map(func(r: RuneData) -> int: return r.level), [1, 3, 1], "the last row went")
	assert_eq(game.profile.essence, third.salvage_value())
	(game.screen.find_child("Salvage1", true, false) as Button).pressed.emit()
	(game.screen.find_child("SalvageYes1", true, false) as Button).pressed.emit()
	assert_eq(game.profile.stash.map(func(r: RuneData) -> int: return r.level), [1, 1], "then the level 3 one")
	game.free()


func test_the_achievements_and_sound_buttons_sit_side_by_side_on_one_line() -> void:
	var game := _game()
	await _tree().process_frame
	await _tree().process_frame
	var trophy := game.screen.find_child("AchievementsButton", true, false) as Button
	var speaker := game.find_child("MuteButton", true, false) as Button
	assert_eq(trophy.global_position.y, speaker.global_position.y, "the same top")
	assert_eq(trophy.size.y, speaker.size.y, "the same height")
	assert_true(trophy.global_position.x + trophy.size.x < speaker.global_position.x, "side by side, not overlapping")
	game.free()


func test_a_web_build_asks_for_a_click_before_the_title_and_the_music_waits_for_it() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE.get_base_dir())
	SaveStore.new(SAVE).delete()
	SettingsStore.new(SETTINGS).delete()
	var game := GAME_SCENE.instantiate() as Game
	game.play_opens_multiplayer = false  # These tests use the single-player hub.
	game.save_path = SAVE
	game.settings_path = SETTINGS
	_tree().root.add_child(game)
	assert_true(game.screen is StartScreen, "the start screen first, on every platform")
	assert_eq(game.audio.current_music, &"", "no music before the click")
	(game.screen.get_node("%StartButton") as Button).pressed.emit()
	assert_true(game.screen is TitleScreen, "the click goes on to the title")
	assert_eq(game.audio.current_music, &"hub", "and the title's music starts from the beginning")
	game.free()


func test_the_start_screen_is_on_by_default_everywhere() -> void:
	var game := GAME_SCENE.instantiate() as Game
	game.play_opens_multiplayer = false  # These tests use the single-player hub.
	assert_true(game.require_click_to_start, "web and desktop open the same way")
	game.free()


func test_the_start_screen_goes_on_with_a_key_but_not_a_held_one_and_only_once() -> void:
	var screen := (load("res://scenes/game/start_screen.tscn") as PackedScene).instantiate() as StartScreen
	_tree().root.add_child(screen)
	var starts := [0]
	screen.started.connect(func() -> void: starts[0] += 1)
	var held := InputEventKey.new()
	held.keycode = KEY_A
	held.pressed = true
	held.echo = true
	screen._unhandled_input(held)
	assert_eq(starts[0], 0, "an auto-repeat doesn't start")
	var key := InputEventKey.new()
	key.keycode = KEY_A
	key.pressed = true
	screen._unhandled_input(key)
	assert_eq(starts[0], 1, "a key press does")
	(screen.get_node("%StartButton") as Button).pressed.emit()
	assert_eq(starts[0], 1, "once only")
	screen.free()


func test_the_title_uses_the_owners_artwork_when_there_is_some_else_the_text() -> void:
	var title := (load("res://scenes/game/title_screen.tscn") as PackedScene).instantiate() as TitleScreen
	_tree().root.add_child(title)
	title.show_title(Game.TITLE)
	title.apply_branding(null, null)
	assert_true(title.get_node("%TitleLabel").visible and not title.get_node("%Logo").visible, "no files: the text title")
	assert_false(title.get_node("%Picture").visible)
	var texture := PlaceholderTexture2D.new()
	texture.size = Vector2(64, 32)
	title.apply_branding(texture, null)
	assert_true(title.get_node("%Logo").visible and not title.get_node("%TitleLabel").visible, "a logo alone replaces the text")
	title.apply_branding(texture, texture)
	assert_false(title.get_node("%Logo").visible or title.get_node("%TitleLabel").visible, "a title picture carries the name itself")
	assert_true(title.get_node("%Picture").visible, "and fills the screen")
	assert_true(absf(title.get_node("%Center").anchor_top - TitleScreen.PICTURE_MENU_TOP) < 0.001, "the menu sits under the picture's name")
	title.apply_branding(null, null)
	assert_eq(title.get_node("%Center").anchor_top, 0.0, "back to the centred menu")
	title.free()
	assert_eq(Game.TITLE, "Rune Ascent")
	assert_eq(ProjectSettings.get_setting("application/config/name"), "Rune Ascent")
	assert_true(ProjectSettings.globalize_path("user://").contains("rune-ascent"), "saves live in the rune-ascent folder: " + ProjectSettings.globalize_path("user://"))


func test_the_shipped_branding_is_found_and_the_start_screen_shows_it() -> void:
	assert_true(Branding.title_image() != null, "ui/branding/title_image.jpg is there")
	assert_eq(ProjectSettings.get_setting("application/config/icon"), "res://ui/branding/icon.png")
	assert_true(load("res://ui/branding/icon.png") is Texture2D)
	var start := (load("res://scenes/game/start_screen.tscn") as PackedScene).instantiate() as StartScreen
	_tree().root.add_child(start)
	start.apply_branding(Branding.title_image())
	assert_true(start.get_node("%Picture").visible and not start.get_node("%TitleLabel").visible)
	start.apply_branding(null)
	assert_true(start.get_node("%TitleLabel").visible and not start.get_node("%Picture").visible)
	start.free()


func test_the_spells_screen_changes_the_loadout_and_saves_it() -> void:
	var game := _game()
	var knight := game.profile.heroes[0]
	knight.level = 3  # Slash, Piercing Thrust, Guard, Whirlwind.
	knight.xp = game.roster.config.xp_for_level(3)  # A save recomputes the level from XP.
	(game.screen as PartyScreen).spells_pressed.emit(0)
	assert_true(game.screen is SpellsScreen, "the spells screen opens")
	var screen := game.screen as SpellsScreen
	(screen.find_child("Slot4", true, false).find_child("Move", true, false) as Button).pressed.emit()
	(screen.find_child("Slot1", true, false).find_child("PutHere", true, false) as Button).pressed.emit()
	assert_eq(knight.spells()[0].display_name, "Whirlwind", "swapped")
	assert_eq(_saved(game).heroes[0].spells()[0].display_name, "Whirlwind", "and saved")
	assert_true(game.screen is SpellsScreen, "still on the spells screen")
	game.screen.back_pressed.emit()
	assert_true(game.screen is PartyScreen, "back to the hub")
	game.free()


func test_a_real_click_on_the_button_starts_but_not_elsewhere() -> void:
	# Through the viewport, as a player's click arrives (GUI routing first), not by calling a handler.
	var screen := (load("res://scenes/game/start_screen.tscn") as PackedScene).instantiate() as StartScreen
	_tree().root.add_child(screen)
	var starts := [0]
	screen.started.connect(func() -> void: starts[0] += 1)
	await _tree().process_frame
	var button := screen.get_node("%StartButton") as Button
	var away := button.get_global_rect().position - Vector2(12, 12)  # Just above and left of it.
	assert_false(button.get_global_rect().has_point(away))
	for spot: Vector2 in [away, button.get_global_rect().get_center()]:
		for pressed in [true, false]:
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = pressed
			click.position = spot
			click.global_position = spot
			screen.get_viewport().push_input(click)
		if spot == away:
			assert_eq(starts[0], 0, "a click away from the button does nothing")
	assert_eq(starts[0], 1, "a click on the button starts")
	screen.free()


func test_click_to_start_pulses() -> void:
	var screen := (load("res://scenes/game/start_screen.tscn") as PackedScene).instantiate() as StartScreen
	_tree().root.add_child(screen)
	var pill := screen.get_node("%StartButton") as Button
	await _tree().create_timer(StartScreen.PULSE_TIME * 0.5).timeout
	assert_true(pill.scale.x > 1.0, "it grows (%s)" % pill.scale)
	assert_eq(pill.pivot_offset_ratio, Vector2(0.5, 0.5), "from its center")
	var center := pill.get_global_rect().get_center()
	assert_true(absf(center.x - screen.size.x / 2.0) < 2.0, "the pill is centered on the screen")
	screen.free()
