extends TestCase
## Achievements: unlocking from the profile and what a battle was, the screen, the toast, the title.

const GAME_SCENE := preload("res://scenes/game/game.tscn")
const SAVE := "user://test_achievements/profile.json"
const SETTINGS := "user://test_achievements/settings.cfg"


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func after_each_clean() -> void:
	SaveStore.new(SAVE).delete()
	SettingsStore.new(SETTINGS).delete()
	DirAccess.remove_absolute(SAVE.get_base_dir())


func _roster() -> Roster:
	return load("res://data/progression/roster.tres") as Roster


func _ids(list: Array[AchievementData]) -> Array:
	return list.map(func(a: AchievementData) -> String: return a.id())


func test_the_shipped_achievements_are_valid_and_unique() -> void:
	var all := Achievements.all()
	assert_true(all.size() >= 10, "about a dozen: %d" % all.size())
	var seen := {}
	for achievement in all:
		assert_eq(achievement.get_validation_errors(), PackedStringArray(), achievement.id())
		assert_false(seen.has(achievement.id()), "unique id %s" % achievement.id())
		seen[achievement.id()] = true


func test_floors_and_levels_unlock_from_the_profile_once() -> void:
	var profile := Profile.create(_roster())
	assert_eq(_ids(Achievements.check(profile)), [], "a new profile has none")
	profile.best_depth = 22
	assert_eq(_ids(Achievements.check(profile)), ["floor_10", "floor_20"])
	assert_eq(_ids(Achievements.check(profile)), [], "each unlocks once")
	profile.heroes[0].level = 30
	assert_eq(_ids(Achievements.check(profile)), ["level_10", "level_30"])
	assert_eq(profile.achievements.size(), 4)
	profile.cleared_stages.append(load("res://data/stages/ruined_gate.tres"))
	assert_eq(_ids(Achievements.check(profile)), ["first_stage"])
	for stage in (load("res://data/tower/tower.tres") as TowerConfig).stages:
		if stage not in profile.cleared_stages:
			profile.cleared_stages.append(stage)
	assert_eq(_ids(Achievements.check(profile)), ["all_stages"])


func test_a_full_rune_set_on_one_hero_unlocks_fully_runed() -> void:
	var profile := Profile.create(_roster())
	var rune := load("res://data/runes/might.tres") as RuneData
	for slot in 5:
		profile.heroes[1].runes[slot] = rune
	assert_eq(_ids(Achievements.check(profile)), [], "five slots are not six")
	profile.heroes[1].runes[5] = rune
	assert_eq(_ids(Achievements.check(profile)), ["full_runes"])


func _state(heroes_alive := true) -> BattleState:
	var hero := BattleFixtures.unit("P0", 200, 3, 6, 20)
	var enemy := BattleFixtures.unit("E0", 100, 3, 6, 20)
	var state := BattleFixtures.state_with("0p 0e", [hero], [enemy])
	if not heroes_alive:
		state.units[0].hp = 0
	return state


func test_what_a_battle_was_unlocks_elite_boss_and_flawless() -> void:
	var profile := Profile.create(_roster())
	var elite := Achievements.Context.from_battle(_state(), 15, false)
	assert_true(elite.elite and not elite.boss and elite.flawless, "floor 15: an elite, flawless")
	assert_eq(_ids(Achievements.check(profile, elite)), ["first_elite", "flawless"])
	var boss := Achievements.Context.from_battle(_state(), 20, false)
	assert_true(boss.boss and not boss.elite)
	assert_eq(_ids(Achievements.check(profile, boss)), ["first_boss"])
	var stage := Achievements.Context.from_battle(_state(), 15, true)
	assert_true(stage.boss and not stage.elite, "a stage counts as a boss fight, never an elite")
	var costly := Achievements.Context.from_battle(_state(false), 3, false)
	assert_false(costly.flawless, "a fallen hero spoils it")
	var other := Profile.create(_roster())
	assert_false(_ids(Achievements.check(other, costly)).has("flawless"))


func _game() -> Game:
	DirAccess.make_dir_recursive_absolute(SAVE.get_base_dir())
	var game := GAME_SCENE.instantiate() as Game
	game.play_opens_multiplayer = false  # These tests use the single-player hub.
	game.require_click_to_start = false  # Straight to the title.
	game.save_path = SAVE
	game.settings_path = SETTINGS
	game.rng_seed = 5
	_tree().root.add_child(game)
	return game


func test_the_achievements_are_saved_and_loaded() -> void:
	var profile := Profile.create(_roster())
	profile.best_depth = 12
	Achievements.check(profile)
	var restored := Profile.from_dict(profile.to_dict(), _roster())
	assert_eq(restored.achievements, ["floor_10"] as Array[String])
	var data := profile.to_dict()
	data["achievements"] = ["floor_10", 7, "floor_10", "nonsense"]
	assert_eq(Profile.from_dict(data, _roster()).achievements, ["floor_10", "nonsense"] as Array[String], "bad entries skipped, duplicates dropped")


func test_a_won_battle_unlocks_toasts_and_saves() -> void:
	var game := _game()
	game.start_tower(1)
	var battle := game.screen as BattleController
	for unit in battle.battle.state.units:
		if unit.team == UnitState.Team.ENEMY:
			unit.hp = 0
	game._apply_battle_result(battle.battle.state)
	assert_true(game.profile.achievements.has("flawless"), "a floor won without losing a hero")
	assert_true(game._toast.visible, "the toast shows")
	assert_true(game._toast_label.text.contains("Flawless"), game._toast_label.text)
	assert_true(SaveStore.new(SAVE).load_or_create(game.roster).achievements.has("flawless"), "and it is saved")
	game.free()


func test_the_hub_opens_the_achievements_screen_and_back_returns() -> void:
	var game := _game()
	(game.screen.find_child("PlayButton", true, false) as Button).pressed.emit()
	game.profile.achievements = ["floor_10"] as Array[String]
	(game.screen.find_child("AchievementsButton", true, false) as Button).pressed.emit()
	assert_true(game.screen is AchievementsScreen)
	var screen := game.screen as AchievementsScreen
	assert_eq(screen.get_node("%Count").text, "1 / %d unlocked" % Achievements.all().size())
	var rows := screen.get_node("%List").get_children()
	assert_eq(rows.size(), Achievements.all().size())
	var done := screen.find_child("Row_floor_10", true, false) as Control
	var locked := screen.find_child("Row_floor_20", true, false) as Control
	assert_true(done.get_child(0).modulate.a > locked.get_child(0).modulate.a, "unlocked ones are lit")
	(screen.get_node("%BackButton") as Button).pressed.emit()
	assert_true(game.screen is PartyScreen, "back to the hub")
	game.free()


func test_the_title_shows_the_best_floor_once_there_is_one() -> void:
	var game := _game()
	var best := game.screen.get_node("%BestLabel") as Label
	assert_false(best.visible, "no floor won yet")
	game.profile.best_depth = 17
	game.show_title()
	best = game.screen.get_node("%BestLabel") as Label
	assert_true(best.visible and best.text.contains("17"), best.text)
	game.free()
