@tool
class_name Battle
extends RefCounted
## Single entry point that mutates a battle: validates an action, applies it, then
## handles deaths, victory and turn changes. Returns every event in order.
## Wrap a clone (Battle.new(state.clone())) to simulate without touching the real battle.
##
## Turn end: the unit's statuses count down (expired ones are removed), then TurnEnded.
## Turn start: TurnStarted, sudden-death damage (party only, late rounds), the unit's
## statuses tick, deaths are checked; a unit killed by
## its own ticks is skipped and the next one starts; otherwise it refills AP and MP.

var state: BattleState
## Stalemate safety net: from this round (0: never), each party unit (every unit in PvP) loses
## sudden_death_percent of its max HP at its turn start, so a stalled battle always ends.
var sudden_death_round := 0
var sudden_death_percent := 10
var _started := false


class Result:
	var error := ""  ## Empty on success.
	var events: Array[BattleEvents.Event] = []

	func ok() -> bool:
		return error.is_empty()


func _init(battle_state: BattleState) -> void:
	state = battle_state


## Starts the first unit's turn. Call once before the first action.
func start() -> Array[BattleEvents.Event]:
	if _started or state.is_over():
		push_error("Battle.start: already started or over")
		return []
	_started = true
	state.started = true
	return _start_turns(false)


func perform(action: BattleActions.Action) -> Result:
	var result := Result.new()
	result.error = action.validate(state)
	if not result.ok():
		return result

	var alive_before := _alive_ids()
	result.events = action.apply(state)
	result.events.append_array(_report_deaths(alive_before))
	if state.is_over():
		return result

	# A turn ends when asked, or when the acting unit died during its own turn.
	var actor := state.units[action.actor_id]
	if action is BattleActions.EndTurn or not actor.is_alive():
		if actor.is_alive():
			result.events.append_array(_end_turn(actor))
		result.events.append_array(_start_turns(true))
	return result


## Statuses count down on the turns that started with them on; expired ones are removed.
func _end_turn(unit: UnitState) -> Array[BattleEvents.Event]:
	var events: Array[BattleEvents.Event] = []
	for status in unit.statuses.duplicate():
		if not status.counting:
			continue
		status.counting = false
		status.turns_left -= 1
		if status.turns_left <= 0:
			unit.statuses.erase(status)
			events.append(BattleEvents.StatusExpired.new(unit.id, status.data))
	unit.commit_position()
	events.append(BattleEvents.TurnEnded.new(unit.id))
	return events


## Starts the next living unit's turn (or the current one's, for the first turn). Loops
## past units that die to their own ticks; stops if the battle ends. Always terminates:
## each pass either starts a living unit's turn or removes a unit from the turn order.
func _start_turns(advance_first: bool) -> Array[BattleEvents.Event]:
	var events: Array[BattleEvents.Event] = []
	var advance := advance_first
	while true:
		if advance:
			state.turn_order.advance()
		advance = true
		var unit := state.current_unit()
		events.append(BattleEvents.TurnStarted.new(unit.id, state.turn_order.round_number, unit.max_ap(), unit.max_mp()))
		var alive_before := _alive_ids()
		events.append_array(_sudden_death(unit))
		events.append_array(_tick_statuses(unit))
		events.append_array(_report_deaths(alive_before))
		if state.is_over():
			break
		if unit.is_alive():
			unit.start_turn()
			break
	return events


## QA cheat: sets a living unit's HP (clamped to its max) and reports it like any change:
## the damage or heal, the deaths, the battle's end, and the next turn if the acting unit fell.
func qa_set_hp(unit_id: int, hp: int) -> Array[BattleEvents.Event]:
	var events: Array[BattleEvents.Event] = []
	var unit := state.units[unit_id]
	if not unit.is_alive() or state.is_over():
		return events
	var alive_before := _alive_ids()
	var target := clampi(hp, 0, unit.max_hp())
	if target < unit.hp:
		events.append(BattleEvents.DamageDealt.new(unit_id, unit.hp - target, target))
	elif target > unit.hp:
		events.append(BattleEvents.Healed.new(unit_id, target - unit.hp, target))
	unit.hp = target
	var acting := state.started and state.turn_order.current_unit_id() == unit_id
	events.append_array(_report_deaths(alive_before))
	if acting and not unit.is_alive() and not state.is_over():
		events.append_array(_start_turns(true))
	return events


func is_sudden_death() -> bool:
	return sudden_death_round > 0 and state.turn_order.round_number >= sudden_death_round


func _sudden_death(unit: UnitState) -> Array[BattleEvents.Event]:
	if (unit.team != UnitState.Team.PLAYER and not state.pvp) or not is_sudden_death() or not unit.is_alive():
		return []
	var amount := mini(maxi(1, roundi(unit.max_hp() * sudden_death_percent / 100.0)), unit.hp)
	unit.hp -= amount
	return [BattleEvents.DamageDealt.new(unit.id, amount, unit.hp)]


## Fires each status's tick effects on its carrier, in application order, as if cast by
## the status's caster (even a dead one). Every status on at turn start counts this turn.
func _tick_statuses(unit: UnitState) -> Array[BattleEvents.Event]:
	var events: Array[BattleEvents.Event] = []
	for status in unit.statuses.duplicate():
		status.counting = true
		if status.data.tick_effects.is_empty() or not unit.is_alive():
			continue
		events.append(BattleEvents.StatusTicked.new(unit.id, status.data, status.turns_left))
		for effect in status.data.tick_effects:
			if unit.is_alive():
				events.append_array(effect.apply(state, status.caster_id, unit.id))
	return events


## Every unit that died since `alive_before` leaves the turn order (UnitDied each); if a
## team is wiped out, BattleEnded follows. Deaths are detected here whatever caused them.
func _report_deaths(alive_before: Array[int]) -> Array[BattleEvents.Event]:
	var events: Array[BattleEvents.Event] = []
	for id in alive_before:
		if not state.units[id].is_alive():
			events.append(BattleEvents.UnitDied.new(id))
			state.turn_order.remove(id)
	if not events.is_empty() and state.is_over():
		events.append(BattleEvents.BattleEnded.new(state.outcome()))
	return events


func _alive_ids() -> Array[int]:
	var ids: Array[int] = []
	for unit in state.units:
		if unit.is_alive():
			ids.append(unit.id)
	return ids
