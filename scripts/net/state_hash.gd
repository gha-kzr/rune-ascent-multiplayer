class_name StateHash
extends RefCounted
## A fingerprint of a battle's state: peers that replay the same actions must end with the same
## number, so a difference means they have drifted apart (a desync). Only whole numbers and
## resource names go in, so it is the same on every platform.


static func of(state: BattleState) -> int:
	var parts: PackedStringArray = []
	parts.append("s%d r%d c%d rng%d" % [1 if state.started else 0, state.turn_order.round_number,
			state.turn_order.current_unit_id(), state.rng.state])
	parts.append("order " + ",".join(Array(state.turn_order.upcoming()).map(func(id: int) -> String: return str(id))))
	for unit in state.units:
		var line := "u%d t%d hp%d c%d,%d ap%d mp%d m%d f%d,%d k%d" % [unit.id, unit.team, unit.hp, unit.cell.x, unit.cell.y,
				unit.ap, unit.mp, 1 if unit.moved else 0, unit.moved_from.x, unit.moved_from.y, unit.moved_cost]
		for status in unit.statuses:
			line += " S%s:%d:%d:%d" % [_name_of(status.data), status.turns_left, status.caster_id, 1 if status.counting else 0]
		var spells: Array[String] = []
		for spell in unit.cooldowns:
			spells.append("%s:%d" % [_name_of(spell), unit.cooldowns[spell]])
		spells.sort()
		line += " C" + ",".join(spells)
		parts.append(line)
	return "\n".join(parts).hash()


static func _name_of(resource: Resource) -> String:
	return resource.resource_path if not resource.resource_path.is_empty() else str(resource.get("display_name"))
