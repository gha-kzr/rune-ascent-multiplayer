extends TestCase
## The first layer of PvP: actions as plain data, the state fingerprint, level-30 heroes, a fair
## (symmetric) map for every shape, and a battle between two human sides.


func _entries(heroes: Array, prefix: String) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for index in heroes.size():
		entries.append({"hero": heroes[index], "name": "%s%d" % [prefix, index]})
	return entries


func _typology(file: String) -> MapTypology:
	return load("res://data/maps/typologies/%s.tres" % file) as MapTypology


func _state(heroes_a := [0], heroes_b := [1], map_seed := 7, size := 12, shape := "open_field") -> BattleState:
	var map := PvpMap.generate(map_seed, _typology(shape), size)
	return PvpBattle.create(map, _entries(heroes_a, "A"), _entries(heroes_b, "B"), 99)


func test_actions_survive_a_trip_through_json() -> void:
	var actions: Array[BattleActions.Action] = [BattleActions.Move.new(3, Vector2i(4, 5)),
			BattleActions.CastSpell.new(2, 1, Vector2i(6, 0)), BattleActions.Place.new(0, Vector2i(7, 7)), BattleActions.EndTurn.new(5)]
	for action in actions:
		var sent := JSON.stringify(ActionCodec.encode(action))
		var received := ActionCodec.decode(JSON.parse_string(sent))
		assert_true(received != null and received.get_script() == action.get_script(), "%s" % sent)
		assert_eq(ActionCodec.encode(received), ActionCodec.encode(action), "the same action")


func test_a_malformed_action_is_null_not_a_crash() -> void:
	for bad in [null, 5, "move", {}, {"t": "move"}, {"t": "move", "a": 1}, {"t": "move", "a": 1.5, "x": 1, "y": 1},
			{"t": "cast", "a": 1, "x": 1, "y": 1}, {"t": "warp", "a": 1}, {"t": "move", "a": "1", "x": 1, "y": 1},
			{"t": "move", "a": 1, "x": 1e12, "y": 1}, {"t": "end"}, [1, 2]]:
		assert_true(ActionCodec.decode(bad) == null, "rejects %s" % str(bad))


func test_the_state_fingerprint_follows_the_state() -> void:
	var first := _state()
	var second := _state()
	assert_eq(StateHash.of(first), StateHash.of(second), "the same battle, the same number")
	second.units[0].hp -= 1
	assert_ne(StateHash.of(first), StateHash.of(second), "one hit point differs")
	var third := _state()
	third.units[1].cell += Vector2i.RIGHT
	assert_ne(StateHash.of(first), StateHash.of(third), "a unit on another cell")
	var fourth := _state()
	fourth.rng.randi()
	assert_ne(StateHash.of(first), StateHash.of(fourth), "a dice roll apart")
	assert_eq(StateHash.of(first), StateHash.of(first.clone()), "a clone matches")


func test_pvp_heroes_have_their_full_kit_and_no_level_in_their_name() -> void:
	for hero in PvpHeroes.hero_count():
		var built := PvpHeroes.build(hero)
		var unit := built["unit"] as UnitData
		assert_eq(unit.spells.size(), HeroRecord.LOADOUT_SLOTS, "%s brings five spells" % unit.display_name)
		assert_false(unit.display_name.contains("Lv"), "no level in the name")
	var knight := PvpHeroes.build(0)
	assert_true((knight["modifiers"] as Array).size() > 0, "level rewards are in")
	var runes := ProgressionConfig.new()
	assert_true(runes != null)


func test_a_pvp_state_has_two_human_sides_with_the_players_names() -> void:
	var state := _state([0, 1], [2, 0])
	assert_true(state.pvp)
	assert_eq(state.units.size(), 4)
	assert_eq(state.units[0].label, "A0")
	assert_eq(state.units[2].label, "B0")
	assert_eq(state.units[0].team, UnitState.Team.PLAYER)
	assert_eq(state.units[2].team, UnitState.Team.ENEMY)
	assert_true(state.units[2].cell in state.zone_enemy, "side B starts in its zone")
	assert_true(state.units[0].cell in state.zone, "side A in its own")
	assert_true(state.units[0].max_hp() > 50, "a level 30 hero, not a fresh one")


func test_both_sides_place_in_their_own_zone_only() -> void:
	var state := _state([0, 1], [2, 0])
	var b_cell: Vector2i = state.zone_enemy[4]
	assert_eq(BattleActions.Place.new(2, b_cell).validate(state), "", "side B places in its zone")
	assert_ne(BattleActions.Place.new(2, state.zone[4]).validate(state), "", "not in the other zone")
	assert_ne(BattleActions.Place.new(0, b_cell).validate(state), "", "nor side A in B's")
	var battle := Battle.new(state)
	battle.perform(BattleActions.Place.new(2, b_cell))
	assert_eq(state.units[2].cell, b_cell)
	battle.perform(BattleActions.Place.new(3, b_cell))
	assert_eq(state.units[3].cell, b_cell, "swapping with a teammate")
	assert_ne(state.units[2].cell, b_cell)


func test_sudden_death_hits_both_sides_in_pvp() -> void:
	var state := _state()
	var battle := Battle.new(state)
	battle.sudden_death_round = 1
	battle.start()
	var hp_before := []
	for unit in state.units:
		hp_before.append(unit.hp)
	# Play until both have had a turn.
	for turn in 2:
		battle.perform(BattleActions.EndTurn.new(state.current_unit().id))
	assert_true(state.units[0].hp < hp_before[0] and state.units[1].hp < hp_before[1], "both heroes lost HP")


func test_pvp_maps_are_valid_symmetric_and_the_same_for_every_peer() -> void:
	for shape in ["open_field", "mountain", "crater", "islands", "canyon", "ruins"]:
		for map_seed in [1, 2, 3]:
			var map := PvpMap.generate(map_seed, _typology(shape), 13)
			var again := PvpMap.generate(map_seed, _typology(shape), 13)
			assert_eq(map.layout, again.layout, "%s %d: the seed fixes the map" % [shape, map_seed])
			var parsed := map.parse()
			assert_true(parsed.grid != null, "%s %d parses" % [shape, map_seed])
			if parsed.grid == null:
				continue
			assert_eq(parsed.player_spawns.size(), 9)
			assert_eq(parsed.enemy_spawns.size(), 9)
			var size := parsed.grid.size
			for y in size.y:
				for x in size.x:
					var cell := Vector2i(x, y)
					var opposite := Vector2i(size.x - 1 - x, size.y - 1 - y)
					assert_eq(parsed.grid.type_at(cell), parsed.grid.type_at(opposite), "%s %d: symmetric at %s" % [shape, map_seed, cell])
					assert_eq(parsed.grid.height_at(cell), parsed.grid.height_at(opposite), "%s %d: same height at %s" % [shape, map_seed, cell])
			for cell in parsed.player_spawns:
				assert_true(Vector2i(size.x - 1 - cell.x, size.y - 1 - cell.y) in parsed.enemy_spawns, "zone B mirrors zone A")
	assert_ne(PvpMap.generate(1, _typology("ruins"), 14).layout, PvpMap.generate(2, _typology("ruins"), 14).layout, "other seeds, other maps")
