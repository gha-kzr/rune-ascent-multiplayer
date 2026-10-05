class_name PvpBattle
extends RefCounted
## Builds a PvP battle's state: side A is the PLAYER team on the map's `p` zone, side B the ENEMY team
## on its `e` zone, every unit a hero at the PvP strength (PvpHeroes). Each unit's label is the name of
## the player who controls it.


## `side_a` and `side_b`: one `{hero: int, name: String}` per player, in the order their units get ids
## (side A first, then side B). Null (with an error) when the map is invalid or a side has no
## player or too many.
static func create(map: MapData, side_a: Array[Dictionary], side_b: Array[Dictionary], battle_seed: int) -> BattleState:
	if side_a.is_empty() or side_b.is_empty():
		push_error("PvpBattle: both sides need a player")
		return null
	var units_a: Array[UnitData] = []
	var modifiers_a: Array = []
	for entry in side_a:
		var built := PvpHeroes.build(int(entry["hero"]))
		units_a.append(built["unit"])
		modifiers_a.append(built["modifiers"])
	var units_b: Array[UnitData] = []
	var builds_b: Array = []
	for entry in side_b:
		var built := PvpHeroes.build(int(entry["hero"]))
		units_b.append(built["unit"])
		var build := EnemyData.Build.new()
		build.unit = built["unit"]
		build.modifiers.assign(built["modifiers"])
		build.label = str(entry["name"])
		builds_b.append(build)
	var parsed := map.parse()
	var state := BattleState.create(parsed, units_a, units_b, battle_seed, modifiers_a, builds_b)
	if state == null:
		return null
	state.pvp = true
	state.zone_enemy = parsed.enemy_spawns.duplicate()
	for index in side_a.size():
		state.units[index].label = str(side_a[index]["name"])
	return state
