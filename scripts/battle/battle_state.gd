@tool
class_name BattleState
extends RefCounted
## Everything that changes during a battle. The rules read and mutate it; views only read it.
## clone() gives an independent copy for AI simulation (Grid and UnitData are shared, read-only).

enum RollBound { NONE, LOWEST, HIGHEST }

## A mutual wipe is a DRAW; the game shows it as a defeat (decision record).
enum Outcome { ONGOING, PLAYER_WON, ENEMY_WON, DRAW }

var grid: Grid
var units: Array[UnitState] = []  ## Indexed by unit id.
var turn_order: TurnOrder
var rng := RandomNumberGenerator.new()
## Simulations (AI) set this so effects use the average roll instead of the dice.
var use_average_rolls := false
## Previews set this to roll every effect at its lowest or highest value (exact bounds).
var roll_bound := RollBound.NONE
## The cells players may start on (the map's player spawns); heroes can be rearranged in
## it until the battle starts.
var zone: Array[Vector2i] = []
## Set by Battle.start(): placement is over.
var started := false
## A fight between two sets of human-controlled heroes (multiplayer): the ENEMY team places in
## `zone_enemy` too, and sudden death hits every unit, not only the PLAYER team.
var pvp := false
var zone_enemy: Array[Vector2i] = []


## Places players in the map's player zone (Placement.default_cells: by role when the zone
## has spare cells, in order otherwise) and enemies on its enemy spawns, in order.
## `player_modifiers[i]` (optional) are player i's permanent modifiers (levels, runes);
## `enemy_builds[i]` (optional) is enemy i's build (level, preset, reward, AI, label).
## `player_hp[i]` (optional) is player i's starting HP (a run's carried-over HP; -1: full).
## Returns null (with an error) if the map is invalid or has too few spawns.
static func create(map: MapData.ParseResult, players: Array[UnitData], enemies: Array[UnitData], rng_seed: int,
		player_modifiers: Array = [], enemy_builds: Array = [], player_hp: Array = []) -> BattleState:
	if map.grid == null:
		push_error("BattleState: invalid map %s" % [map.errors])
		return null
	if players.size() > map.player_spawns.size() or enemies.size() > map.enemy_spawns.size():
		push_error("BattleState: %d/%d units for %d/%d spawns" % [
				players.size(), enemies.size(), map.player_spawns.size(), map.enemy_spawns.size()])
		return null

	if players.has(null) or enemies.has(null):
		push_error("BattleState: empty unit slot in a team")
		return null

	var state := BattleState.new()
	state.grid = map.grid
	state.zone = map.player_spawns.duplicate()
	var starts := Placement.default_cells(map.grid, map.player_spawns, map.enemy_spawns, players)
	for i in players.size():
		var unit := UnitState.new(state.units.size(), players[i], UnitState.Team.PLAYER, starts[i])
		if i < player_modifiers.size():
			unit.permanent_modifiers.assign(player_modifiers[i])
			unit.hp = unit.max_hp()
			unit.start_turn()
		if i < player_hp.size() and int(player_hp[i]) >= 0:
			unit.hp = clampi(int(player_hp[i]), 1, unit.max_hp())
		state.units.append(unit)
	for i in enemies.size():
		var unit := UnitState.new(state.units.size(), enemies[i], UnitState.Team.ENEMY, map.enemy_spawns[i])
		if i < enemy_builds.size():
			var build: EnemyData.Build = enemy_builds[i]
			unit.permanent_modifiers.assign(build.modifiers)
			unit.reward = build.reward
			unit.ai_profile = build.ai_profile
			unit.label = build.label
			unit.role = build.role
			unit.positioning = build.positioning
			unit.visual_scale = build.visual_scale
			unit.hp = unit.max_hp()
			unit.start_turn()
		state.units.append(unit)
	state.turn_order = TurnOrder.from_units(state.units)
	state.rng.seed = rng_seed
	return state


## Rolls an amount in [low, high] for an effect. With use_average_rolls, returns the
## average rounded down (conservative: a kill only counts if the average roll kills).
func roll(low: int, high: int) -> int:
	if roll_bound == RollBound.LOWEST:
		return low
	if roll_bound == RollBound.HIGHEST:
		return high
	if use_average_rolls:
		return floori((low + high) / 2.0)
	return rng.randi_range(low, high)


func current_unit() -> UnitState:
	var id := turn_order.current_unit_id()
	return units[id] if id >= 0 else null


func unit_at(cell: Vector2i) -> UnitState:
	for unit in units:
		if unit.is_alive() and unit.cell == cell:
			return unit
	return null


func is_occupied(cell: Vector2i) -> bool:
	return unit_at(cell) != null


func alive_units(team: UnitState.Team) -> Array[UnitState]:
	return units.filter(func(unit: UnitState) -> bool: return unit.is_alive() and unit.team == team)


func outcome() -> Outcome:
	var players_alive := not alive_units(UnitState.Team.PLAYER).is_empty()
	var enemies_alive := not alive_units(UnitState.Team.ENEMY).is_empty()
	if players_alive and enemies_alive:
		return Outcome.ONGOING
	if players_alive:
		return Outcome.PLAYER_WON
	if enemies_alive:
		return Outcome.ENEMY_WON
	return Outcome.DRAW


func is_over() -> bool:
	return outcome() != Outcome.ONGOING


func clone() -> BattleState:
	var copy := BattleState.new()
	copy.grid = grid
	for unit in units:
		copy.units.append(unit.clone())
	copy.turn_order = turn_order.clone()
	copy.rng.seed = rng.seed
	copy.rng.state = rng.state
	copy.use_average_rolls = use_average_rolls
	copy.roll_bound = roll_bound
	copy.zone = zone.duplicate()
	copy.pvp = pvp
	copy.zone_enemy = zone_enemy.duplicate()
	copy.started = started
	return copy
