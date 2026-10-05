class_name ActionCodec
extends RefCounted
## Battle actions as plain dictionaries (JSON-safe), so they can travel between peers. Decoding is
## strict: whatever a peer sends is untrusted, a malformed action is null, never a crash.
## Kinds: move (a, x, y), cast (a, s, x, y), place (a, x, y), end (a).


static func encode(action: BattleActions.Action) -> Dictionary:
	if action is BattleActions.Move:
		var move := action as BattleActions.Move
		return {"t": "move", "a": move.actor_id, "x": move.destination.x, "y": move.destination.y}
	if action is BattleActions.CastSpell:
		var cast := action as BattleActions.CastSpell
		return {"t": "cast", "a": cast.actor_id, "s": cast.spell_index, "x": cast.target.x, "y": cast.target.y}
	if action is BattleActions.Place:
		var place := action as BattleActions.Place
		return {"t": "place", "a": place.actor_id, "x": place.cell.x, "y": place.cell.y}
	if action is BattleActions.EndTurn:
		return {"t": "end", "a": action.actor_id}
	push_error("ActionCodec: can't encode %s" % action)
	return {}


## The action, or null when `data` isn't a well-formed one.
static func decode(data: Variant) -> BattleActions.Action:
	if data is not Dictionary:
		return null
	var fields := data as Dictionary
	var actor: Variant = _int(fields.get("a"))
	if actor == null:
		return null
	match fields.get("t"):
		"move":
			var cell: Variant = _cell(fields)
			return BattleActions.Move.new(actor, cell) if cell != null else null
		"cast":
			var slot: Variant = _int(fields.get("s"))
			var target: Variant = _cell(fields)
			return BattleActions.CastSpell.new(actor, slot, target) if slot != null and target != null else null
		"place":
			var cell: Variant = _cell(fields)
			return BattleActions.Place.new(actor, cell) if cell != null else null
		"end":
			return BattleActions.EndTurn.new(actor)
	return null


## A whole number (JSON gives floats), or null.
static func _int(value: Variant) -> Variant:
	if value is int:
		return value
	if value is float and is_equal_approx(value, roundf(value)) and absf(value) < 1.0e9:
		return int(value)
	return null


static func _cell(fields: Dictionary) -> Variant:
	var x: Variant = _int(fields.get("x"))
	var y: Variant = _int(fields.get("y"))
	return Vector2i(x, y) if x != null and y != null else null
