@tool
class_name BattleActions
extends RefCounted
## Player and AI commands (command pattern). An action names its actor by id and holds
## only its intent; validate() and apply() resolve everything against the state they're
## given, so the same action can be tried on an AI clone and then on the real battle.
## Apply only through Battle.perform(), which validates first and handles turn flow.


@abstract class Action extends RefCounted:
	var actor_id: int

	## Empty string if the action is legal in `state`, otherwise the reason it isn't.
	func validate(state: BattleState) -> String:
		if state.is_over():
			return "the battle is over"
		if not state.started:
			return "the battle hasn't started"
		if actor_id < 0 or actor_id >= state.units.size():
			return "unknown unit %d" % actor_id
		if not state.units[actor_id].is_alive():
			return "unit %d is dead" % actor_id
		if state.turn_order.current_unit_id() != actor_id:
			return "it is not unit %d's turn" % actor_id
		return _validate(state)

	@abstract func _validate(state: BattleState) -> String

	## Mutates `state` and returns what happened. Assumes validate() passed.
	@abstract func apply(state: BattleState) -> Array[BattleEvents.Event]


class Move extends Action:
	var destination: Vector2i

	func _init(actor: int, cell: Vector2i) -> void:
		actor_id = actor
		destination = cell

	func _validate(state: BattleState) -> String:
		if not Movement.reach(state, actor_id).can_reach(destination):
			return "can't reach %s" % destination
		return ""

	## Repositioning (see UnitState): the cost counts from where the move segment started,
	## so moving again re-spends from the segment's MP; the drawn path is the walk from
	## where the unit stands (a straight slide when no walk leads there).
	func apply(state: BattleState) -> Array[BattleEvents.Event]:
		var reach := Movement.reach(state, actor_id)
		var unit := state.units[actor_id]
		var path := reach.path_to(destination) if not unit.moved else Movement.walk_path(state, actor_id, destination)
		if path.is_empty():
			path = [destination]
		var mp_before := unit.mp
		if not unit.moved:
			unit.moved = true
			unit.moved_from = unit.cell
		unit.moved_cost = reach.cost_to(destination)
		unit.mp = reach.origin_budget - unit.moved_cost
		unit.cell = destination
		return [BattleEvents.UnitMoved.new(actor_id, path, mp_before - unit.mp)]


class CastSpell extends Action:
	var spell_index: int
	var target: Vector2i

	func _init(actor: int, spell_slot: int, target_cell: Vector2i) -> void:
		actor_id = actor
		spell_index = spell_slot
		target = target_cell

	## Whether the unit has that spell, enough AP for it and no cooldown on it (range aside).
	## Shared with the UI.
	static func can_afford(unit: UnitState, slot: int) -> bool:
		return slot >= 0 and slot < unit.data.spells.size() and unit.ap >= unit.data.spells[slot].ap_cost \
				and unit.cooldown_left(unit.data.spells[slot]) == 0

	func _validate(state: BattleState) -> String:
		var unit := state.units[actor_id]
		if spell_index < 0 or spell_index >= unit.data.spells.size():
			return "unit %d has no spell %d" % [actor_id, spell_index]
		var spell := unit.data.spells[spell_index]
		if unit.ap < spell.ap_cost:
			return "%s needs %d AP, unit has %d" % [spell.display_name, spell.ap_cost, unit.ap]
		if unit.cooldown_left(spell) > 0:
			return "%s is on cooldown for %d turns" % [spell.display_name, unit.cooldown_left(spell)]
		if not Targeting.can_target(state, actor_id, spell, target):
			return "%s can't target %s" % [spell.display_name, target]
		return ""

	func apply(state: BattleState) -> Array[BattleEvents.Event]:
		var caster := state.units[actor_id]
		var spell := caster.data.spells[spell_index]
		caster.ap -= spell.ap_cost
		if spell.cooldown > 0:
			caster.cooldowns[spell] = spell.cooldown
		var area := Targeting.area_cells(state.grid, spell.area, caster.cell, target)
		var events: Array[BattleEvents.Event] = [BattleEvents.SpellCast.new(actor_id, spell, target, area, spell.ap_cost)]
		# Targets are fixed before any effect lands, in area order.
		var in_area: Array[int] = []
		for cell in area:
			var unit := state.unit_at(cell)
			if unit != null:
				in_area.append(unit.id)
		# Effect by effect: every hit lands, then every status, and so on.
		for effect in spell.effects:
			for target_id in _targets_of(effect, state, in_area):
				if state.units[target_id].is_alive():  # Killed by an earlier effect: skipped.
					events.append_array(effect.apply_cast(state, actor_id, target_id, target))
		caster.commit_position()  # A cast ends free repositioning: the next move counts from here.
		return events

	## The units an effect applies to, by its target filter.
	func _targets_of(effect: EffectData, state: BattleState, in_area: Array[int]) -> Array[int]:
		var caster_team := state.units[actor_id].team
		match effect.target_filter:
			EffectData.TargetFilter.CASTER:
				return [actor_id]
			EffectData.TargetFilter.ALLIES:
				return in_area.filter(func(id: int) -> bool: return state.units[id].team == caster_team)
			EffectData.TargetFilter.ENEMIES:
				return in_area.filter(func(id: int) -> bool: return state.units[id].team != caster_team)
		return in_area


## Before the battle starts: moves a hero to a cell of its start zone, swapping with a hero of its
## team standing there, if any. In a PvP battle the ENEMY team places in its own zone too.
class Place extends Action:
	var cell: Vector2i

	func _init(actor: int, zone_cell: Vector2i) -> void:
		actor_id = actor
		cell = zone_cell

	func validate(state: BattleState) -> String:
		if state.started:
			return "the battle has started"
		if actor_id < 0 or actor_id >= state.units.size():
			return "unknown unit %d" % actor_id
		if state.units[actor_id].team != UnitState.Team.PLAYER and not state.pvp:
			return "only heroes are placed"
		if not state.units[actor_id].is_alive():
			return "unit %d is dead" % actor_id
		return _validate(state)

	func _validate(state: BattleState) -> String:
		var zone := state.zone if state.units[actor_id].team == UnitState.Team.PLAYER else state.zone_enemy
		if cell not in zone:
			return "%s isn't in the start zone" % cell
		return ""

	func apply(state: BattleState) -> Array[BattleEvents.Event]:
		var unit := state.units[actor_id]
		if unit.cell == cell:
			return []
		var events: Array[BattleEvents.Event] = []
		var other := state.unit_at(cell)
		if other != null and other.team == unit.team:
			other.cell = unit.cell
			events.append(BattleEvents.UnitPlaced.new(other.id, other.cell))
		unit.cell = cell
		events.push_front(BattleEvents.UnitPlaced.new(actor_id, cell))
		return events


class EndTurn extends Action:
	func _init(actor: int) -> void:
		actor_id = actor

	func _validate(_state: BattleState) -> String:
		return ""

	func apply(_state: BattleState) -> Array[BattleEvents.Event]:
		return []  # Battle.perform() handles the turn change.
