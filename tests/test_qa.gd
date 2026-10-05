extends TestCase
## The QA tools: their rules (quick teams, playground boards, profile tools) and the Game's
## QA flow, which never touches the save.

const GAME_SCENE := preload("res://scenes/game/game.tscn")
const SAVE := "user://test_qa/profile.json"
const SETTINGS := "user://test_qa/settings.cfg"


func _roster() -> Roster:
	return load("res://data/progression/roster.tres") as Roster


func _tower() -> TowerConfig:
	return load("res://data/tower/tower.tres") as TowerConfig


func test_a_quick_team_has_its_levels_and_runes() -> void:
	var team := QaTools.quick_team(_roster(), [7, 0, 12] as Array[int], RuneData.Rarity.RARE)
	assert_eq(team.units.size(), 2, "the Mage (level 0) left out")
	assert_eq(team.levels, [7, 12] as Array[int])
	assert_eq(team.units[0].spells.size(), mini(HeroRecord.LOADOUT_SLOTS, team.units[0].spells.size()), "the default loadout")
	var rares := QaTools.runes_of(RuneData.Rarity.RARE)
	assert_true(not rares.is_empty() and rares.all(func(r: RuneData) -> bool: return r.rarity == RuneData.Rarity.RARE))
	var bare := QaTools.quick_team(_roster(), [7, 0, 12] as Array[int], QaTools.NO_RUNES)
	assert_true(team.modifiers[0].size() > bare.modifiers[0].size(), "runes add modifiers")


func test_a_playground_board_fits_its_enemies() -> void:
	var brute := load("res://data/enemies/brute.tres") as EnemyData
	var enemies := [[brute, 4, 0], [brute, 4, 1], [brute, 4, 2], [brute, 2, 0], [brute, 2, 0]]
	var crater := load("res://data/maps/typologies/crater.tres") as MapTypology
	var encounter := QaTools.playground(_tower(), 7, crater, 14, enemies)
	var parsed := encounter.map.parse()
	assert_eq(parsed.enemy_spawns.size(), 5, "a spawn per enemy")
	assert_eq(encounter.get_validation_errors(), PackedStringArray())
	assert_eq(encounter.spawns[2].preset, load("res://data/presets/boss.tres"), "the third is a boss")
	assert_eq(encounter.map_typology, crater)
	assert_true(QaTools.describe(encounter).contains("Crater"), QaTools.describe(encounter))
	var again := QaTools.playground(_tower(), 7, crater, 14, enemies)
	assert_eq(again.map.layout, encounter.map.layout, "the same seed, the same board")


func test_a_floor_describes_its_shape_and_team() -> void:
	var encounter := FloorGenerator.encounter(_tower(), 27)
	var text := QaTools.describe(encounter)
	assert_true(encounter.composition != null and text.contains(encounter.composition.label), text)
	assert_true(text.contains(QaTools.kind_text(encounter.map_typology.kind)), text)


func test_the_playground_can_use_a_floors_own_map() -> void:
	var brute := load("res://data/enemies/brute.tres") as EnemyData
	var floor_encounter := FloorGenerator.encounter(_tower(), 27)
	var own := QaTools.playground(_tower(), 27, null, 0, [[brute, 4, 0]])
	assert_eq(own.map.layout.replace("e", ""), floor_encounter.map.layout.replace("e", ""), "the floor's own cells")
	assert_eq(own.map.parse().enemy_spawns, floor_encounter.map.parse().enemy_spawns.slice(0, 1), "its first spawn")
	assert_eq(own.map_typology, floor_encounter.map_typology)
	var crowd := []
	for i in floor_encounter.map.parse().enemy_spawns.size() + 1:
		crowd.append([brute, 2, 0])
	var redrawn := QaTools.playground(_tower(), 27, null, 0, crowd)
	assert_eq(redrawn.map.parse().enemy_spawns.size(), crowd.size(), "more enemies: a map of that shape drawn for them")
	assert_eq(redrawn.map_typology, floor_encounter.map_typology)


func test_the_profile_tools() -> void:
	var profile := Profile.create(_roster())
	QaTools.set_levels(profile, 14)
	assert_true(profile.heroes.all(func(r: HeroRecord) -> bool: return r.level == 14 and r.xp == profile.roster.config.xp_for_level(14)))
	QaTools.give_every_rune(profile)
	assert_eq(profile.stash.size(), ResourceLoader.list_directory("res://data/runes").size())
	QaTools.give_every_rune(profile, 4)
	assert_eq(profile.stash.back().level, 4, "at the asked level")
	QaTools.give_essence(profile, 50)
	assert_eq(profile.essence, 50)
	QaTools.set_best_floor(profile, 33)
	assert_eq(profile.best_depth, 33)
	QaTools.clear_every_stage(profile, _tower())
	assert_eq(profile.cleared_stages.size(), _tower().stages.size())
	assert_eq(QaTools.start_run_at(profile, _tower(), 25), "")
	assert_eq(profile.run.floor_number, 25)
	assert_eq(QaTools.start_run_at(profile, _tower(), 999), "")
	assert_eq(profile.run.floor_number, profile.tower_cap(_tower()), "at most the top floor")
	var fresh := Profile.create(_roster())
	QaTools.start_run_at(fresh, _tower(), 25)
	assert_eq(fresh.run.floor_number, _tower().initial_cap, "no stage cleared: the first top floor")


# --- The Game's QA flow ---

func _open(qa_on: bool) -> Game:
	DirAccess.make_dir_recursive_absolute(SAVE.get_base_dir())
	SaveStore.new(SAVE).delete()
	var settings := Settings.new()
	settings.qa_tools = qa_on
	settings.battle_speed = Settings.BattleSpeed.INSTANT
	SettingsStore.new(SETTINGS).save(settings)
	var game := GAME_SCENE.instantiate() as Game
	game.play_opens_multiplayer = false  # These tests use the single-player hub.
	game.save_path = SAVE
	game.settings_path = SETTINGS
	game.rng_seed = 5
	game.require_click_to_start = false
	(Engine.get_main_loop() as SceneTree).root.add_child(game)
	return game


func after_each_clean() -> void:
	SaveStore.new(SAVE).delete()
	SettingsStore.new(SETTINGS).delete()
	DirAccess.remove_absolute(SAVE.get_base_dir())


func test_the_qa_button_follows_the_setting() -> void:
	var game := _open(false)
	assert_false((game.screen.find_child("QaButton", true, false) as Button).visible, "off by default")
	game.free()
	game = _open(true)
	assert_true((game.screen.find_child("QaButton", true, false) as Button).visible)
	(game.screen.find_child("QaButton", true, false) as Button).pressed.emit()
	assert_true(game.screen is QaScreen)
	game.free()


func test_the_floor_browser_flips_floors() -> void:
	var game := _open(true)
	game.show_qa()
	var qa := game.screen as QaScreen
	var spin := qa.find_child("FloorNumber", true, false) as SpinBox
	(qa.find_child("NextFloor", true, false) as Button).pressed.emit()
	assert_eq(int(spin.value), 2)
	spin.value = 30
	assert_true(qa.state.floor_number == 30)
	game.free()


func test_a_qa_battle_returns_to_the_qa_screen_and_saves_nothing() -> void:
	var game := _open(true)
	game.show_qa()
	var before := JSON.stringify(game.profile.to_dict())
	var file_before := FileAccess.get_file_as_string(SAVE) if FileAccess.file_exists(SAVE) else ""
	(game.screen.find_child("FightFloor", true, false) as Button).pressed.emit()
	var battle := game.screen as BattleController
	assert_true(battle != null and battle.qa_battle, "a QA battle")
	battle.end_turn()  # Ready.
	assert_true(await _wait_for(battle, [BattleController.State.IDLE]), "the heroes' turn")
	battle.qa_cheat(&"win")
	assert_true(await _wait_for(battle, [BattleController.State.ENDED]), "the cheat wins")
	(battle.hud.get_node("%RestartButton") as Button).pressed.emit()
	assert_true(game.screen is QaScreen, "back to the QA screen")
	assert_eq(JSON.stringify(game.profile.to_dict()), before, "no XP, runes or progress")
	var file_after := FileAccess.get_file_as_string(SAVE) if FileAccess.file_exists(SAVE) else ""
	assert_eq(file_after, file_before, "and nothing written")
	game.free()


func test_leaving_a_qa_battle_returns_to_the_qa_screen() -> void:
	var game := _open(true)
	game.show_qa()
	var file_before := FileAccess.get_file_as_string(SAVE) if FileAccess.file_exists(SAVE) else ""
	(game.screen.find_child("FightFloor", true, false) as Button).pressed.emit()
	var battle := game.screen as BattleController
	(battle.hud.get_node("%MenuButton") as Button).pressed.emit()
	(battle.hud.get_node("%LeaveButton") as Button).pressed.emit()
	assert_true(game.screen is QaScreen, "back to the QA screen")
	assert_eq(FileAccess.get_file_as_string(SAVE) if FileAccess.file_exists(SAVE) else "", file_before, "nothing written")
	game.free()


func test_one_quick_team_and_the_tab_is_kept() -> void:
	var game := _open(true)
	game.show_qa()
	var qa := game.screen as QaScreen
	assert_eq(qa.find_children("HeroLevel0", "SpinBox", true, false).size(), 1, "one quick team for both tabs")
	(qa.find_child("Tabs", true, false) as TabContainer).current_tab = 1
	game.show_qa()
	assert_eq(((game.screen as QaScreen).find_child("Tabs", true, false) as TabContainer).current_tab, 1, "the Playground tab again")
	game.free()


func _wait_for(battle: BattleController, wanted: Array) -> bool:
	for i in 3000:
		if battle.input_state in wanted:
			return true
		await (Engine.get_main_loop() as SceneTree).process_frame
	return false


func test_a_profile_tool_applies_and_saves() -> void:
	var game := _open(true)
	game.show_qa()
	var qa := game.screen as QaScreen
	qa.state.profile_value = 12
	qa.profile_action.emit(&"set_levels", 12)
	assert_eq(game.profile.heroes[1].level, 12)
	assert_eq(SaveStore.new(SAVE).load_or_create(game.roster).heroes[1].level, 12, "saved")
	game.free()
