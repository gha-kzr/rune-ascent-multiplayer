class_name NetBattleController
extends BattleController
## The multiplayer fight, on the same screen as every other battle. The battle itself lives in the
## MatchSession (the replicated log); this view keeps its own copy of the battle and animates what the
## log brings, one entry at a time: placement moves, the first turn, moves and casts, whoever made
## them. What the local player does becomes a proposal to the host; nothing changes on screen until
## the host's entry comes back. A hero played by the AI, or by a player who left, is simply a turn
## that is not mine: the screen waits and watches.

var session: MatchSession

var _queue: Array[Dictionary] = []
## The log entry (its number) this view has applied up to.
var _applied := 0
## Whether the local player's action is on its way to the host and back.
var _awaiting := false
## Whether an entry is being played (the next waits for it).
var _busy := false
## The player pressed Ready for their placement.
var _placed_pressed := false
var _status: NetStatusPanel


## Call before the controller enters the tree.
func setup_net(match_session: MatchSession) -> void:
	session = match_session
	standalone = false
	sudden_death_round = MatchState.SUDDEN_DEATH_ROUND
	sudden_death_percent = MatchState.SUDDEN_DEATH_PERCENT
	battle_seed = int(session.state.settings["seed"])


func _ready() -> void:
	super._ready()
	hud.set_result_action_text("Back to the lobby")
	session.entry_applied.connect(_on_entry)
	session.rejected.connect(_on_rejected)
	_status = NetStatusPanel.new()
	hud.get_node("Root").add_child(_status)
	_status.bind(session)
	_catch_up()


func _create_battle_state() -> BattleState:
	var made := session.state.make_battle()
	return made.state if made != null else null


## The start zone the local player's hero places in (its side's), highlighted while placing.
func _placement_zone() -> Array[Vector2i]:
	return _zone_of(_my_unit())


func _placement_zone_for_camera(battle_state: BattleState) -> Array[Vector2i]:
	var mine := session.unit_of(session.my_id)
	if mine >= 0 and mine < battle_state.units.size() and battle_state.units[mine].team == UnitState.Team.ENEMY:
		return battle_state.zone_enemy
	return battle_state.zone


func _zone_of(unit_id: int) -> Array[Vector2i]:
	if unit_id < 0 or battle == null:
		return battle.state.zone if battle != null else []
	return battle.state.zone if battle.state.units[unit_id].team == UnitState.Team.PLAYER else battle.state.zone_enemy


func _my_unit() -> int:
	return session.unit_of(session.my_id)


# --- The log, one entry at a time -----------------------------------------------------------

## A view that opens late (a returning player, or a late start) replays what already happened, without
## animation, then shows where things stand.
func _catch_up() -> void:
	var log := session.state.log
	var start := -1
	for index in log.size():
		if log[index]["k"] == "start":
			start = index
	_applied = start + 1
	for index in range(start + 1, log.size()):
		_apply_silently(log[index])
		_applied = index + 1
	_sync_labels()
	units_view.sync(battle.state)
	_begin_next()
	if battle.state.started:
		units_view.set_active(battle.state.current_unit().id if not battle.state.is_over() else -1)


func _apply_silently(entry: Dictionary) -> void:
	match entry["k"]:
		"act":
			var action := ActionCodec.decode(entry["a"])
			if action != null:
				battle.perform(action)
		"go":
			battle.start()


func _on_entry(entry: Dictionary) -> void:
	if int(entry["n"]) <= _applied or battle == null:
		return
	_queue.append(entry)
	_pump()


func _pump() -> void:
	if _busy:
		return
	while not _queue.is_empty():
		var entry: Dictionary = _queue.pop_front()
		_applied = int(entry["n"])
		if _play_entry(entry):
			return
	_begin_next()


## Applies one entry to this view's battle. True when events started playing (the next entry waits).
func _play_entry(entry: Dictionary) -> bool:
	match entry["k"]:
		"act":
			if entry.get("by") == session.my_id and entry.get("sys") != true:
				_awaiting = false
			var action := ActionCodec.decode(entry["a"])
			if action == null:
				return false
			var result := battle.perform(action)
			if not result.ok():
				push_error("NetBattle: the host's action doesn't fit this view: %s" % result.error)
				return false
			_busy = true
			_play(result.events)
			return true
		"go":
			_busy = true
			_play(battle.start())
			return true
		"ai", "join", "drop":
			_sync_labels()
			_refresh_hud()
	return false


func _sync_labels() -> void:
	for seat_id in session.state.seat_ids():
		var unit_id := session.unit_of(seat_id)
		if unit_id < 0 or unit_id >= battle.state.units.size():
			continue
		var seat := session.state.seats[seat_id]
		battle.state.units[unit_id].label = seat.name + (" " + tr("(AI)") if seat.ai else "")


func _on_rejected(reason: String) -> void:
	_awaiting = false
	push_warning("NetBattle: refused: %s" % reason)
	hud.show_banner(tr("That isn't possible right now."))
	if not _busy:
		_begin_next()


# --- Turns ----------------------------------------------------------------------------------

func _begin_next() -> void:
	_busy = false
	_refresh_hud()
	if not _queue.is_empty():
		_pump()
		return
	var battle_state := battle.state
	if not battle_state.started:
		_set_state(State.PLACING)
		return
	units_view.set_active(battle_state.current_unit().id if not battle_state.is_over() else -1)
	if battle_state.is_over():
		_finish()
	elif _awaiting:
		_set_state(State.ANIMATING)  # My action is on its way: nothing to do until it comes back.
	elif session.controls_unit(battle_state.current_unit().id):
		_enter_idle()
	else:
		_set_state(State.ENEMY_TURN)  # Someone else's turn (a player, or the AI): watch.


func _finish() -> void:
	_set_state(State.ENDED)
	var mine := session.state.seats.get(session.my_id) as MatchState.Seat
	var my_team := UnitState.Team.PLAYER if mine == null or mine.side == 0 else UnitState.Team.ENEMY
	var outcome := battle.state.outcome()
	var winners := UnitState.Team.PLAYER if outcome == BattleState.Outcome.PLAYER_WON else UnitState.Team.ENEMY
	var won := (outcome == BattleState.Outcome.PLAYER_WON and my_team == UnitState.Team.PLAYER) \
			or (outcome == BattleState.Outcome.ENEMY_WON and my_team == UnitState.Team.ENEMY)
	sound.emit(&"victory" if won else &"defeat")
	if outcome != BattleState.Outcome.DRAW:
		_cheer(winners, battle.state)
	hud.show_result(won, battle_seed)
	battle_ended.emit(battle.state)


func _set_state(new_state: State) -> void:
	if new_state == State.PLACING:
		_placing_hero = _my_unit()
	super._set_state(new_state)
	if new_state == State.PLACING and _placed_pressed:
		hud.set_player_controls_enabled(false)  # Ready was pressed: nothing more to do but wait.


func _turn_banner_name(unit: UnitState) -> String:
	return unit.label


func _prompt_text() -> String:
	if input_state == State.PLACING:
		if _placed_pressed:
			return tr("Ready. Waiting for the other players...")
		return tr("Click a teal cell to place your hero, then press Ready (%s)") % SettingsApplier.key_text(&"end_turn")
	if input_state == State.ENEMY_TURN and battle.state.started and not battle.state.is_over():
		var seat_id := session.state.seat_of_unit(battle.state.current_unit().id)
		var seat := session.state.seats.get(seat_id) as MatchState.Seat
		if seat != null and not seat.connected and not seat.ai:
			return tr("%s is away: the AI takes over soon") % seat.name
	return super._prompt_text()


# --- What the local player does -------------------------------------------------------------

func _perform(action: BattleActions.Action) -> void:
	_awaiting = true
	session.act(action)
	if _awaiting and not _busy:  # It hasn't come back yet (it never does at once for a guest).
		_set_state(State.ANIMATING)


func end_turn() -> void:
	if input_state == State.PLACING:
		if _placed_pressed:
			return
		_placed_pressed = true
		session.set_placed(true)
		_set_state(State.PLACING)
	elif input_state == State.IDLE or input_state == State.TARGETING:
		_perform(BattleActions.EndTurn.new(battle.state.current_unit().id))


func click_cell(cell: Vector2i) -> void:
	if battle == null:
		return
	var clicked := battle.state.unit_at(cell)
	var acted := false
	match input_state:
		State.PLACING:
			if not _placed_pressed and cell in _zone_of(_my_unit()):
				acted = true
				_perform(BattleActions.Place.new(_my_unit(), cell))
		State.IDLE:
			if _reach != null and _reach.can_reach(cell):
				acted = true
				_perform(BattleActions.Move.new(battle.state.current_unit().id, cell))
		State.TARGETING:
			if _targetable.has(cell):
				acted = true
				_perform(BattleActions.CastSpell.new(battle.state.current_unit().id, selected_spell, cell))
	if clicked != null and not acted and clicked.id != _active_card_unit_id():
		pin(clicked.id)
