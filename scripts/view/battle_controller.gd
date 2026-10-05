class_name BattleController
extends Node3D
## Battle scene root: creates the battle, wires views, HUD and camera, and runs the turn
## loop. Player clicks and AI choices both become actions that go through the same path:
## Battle.perform() → EventPlayer.play() → views sync to the state → next turn.
##
## Input states (enum FSM): IDLE (player's turn, moving), TARGETING (a spell is aimed),
## ANIMATING (events playing), ENEMY_TURN (the AI is acting), ENDED (result shown).
## Signals up from the HUD and camera, calls down to them.
##
## Standalone (battle.tscn run on its own) it plays from its exports and the result
## screen offers "Play again". Run by the Game root, setup() injects the battle before it
## enters the tree, and the result screen's "Continue" emits battle_finished.

## The battle just ended (the result screen shows). The state is final: the caller applies
## and saves rewards now, so closing the game on the result screen loses nothing.
## A sound to hear (an AudioSet.SFX_EVENTS name), from the playback or the turn flow.
signal sound(event: StringName)

## The battle speed was changed with the HUD button (the Game root saves the settings).
signal speed_changed

## A tutorial step was finished or skipped (the Game root saves the settings).
signal tutorial_changed

signal battle_ended(state: BattleState)
## The player left the fight from the HUD's menu: nothing from it is kept.
signal left_battle
## A battle set up by setup() ended and the player chose to continue.
signal battle_finished(state: BattleState)

## PLACING: before the first turn, heroes are rearranged in the start zone until Ready.
enum State { PLACING, IDLE, TARGETING, ANIMATING, ENEMY_TURN, ENDED }

## The web build's Compatibility renderer lights the same scene brighter than Forward+
## (no filmic tonemapping), so its lights are scaled down.
const WEB_LIGHT_SCALE := 0.6

## Where the camera starts: this far from the board's centre toward the start zone (0 to 1).
const START_FOCUS_TOWARD_ZONE := 0.35
## Pause before each AI action, so the player can follow what happens.
const ENEMY_ACTION_DELAY := 0.35
## Time scale of the "fast" battle speed.
const FAST_TIME_SCALE := 2.0
## Pause before the turn ends by itself (auto end turn), so the player sees what happened.
const AUTO_END_DELAY := 0.5
## How long the camera takes to reach an enemy that starts its turn off screen.
const ENEMY_FOCUS_DURATION := 0.45

## The fight: map, enemies (levels, presets) and their AI profile.
@export var encounter: Encounter
@export var players: Array[UnitData] = []
## Fallback AI profile when neither the enemy's preset nor the encounter sets one.
@export var ai_profile: AIProfile
## 0 picks a random seed for each battle.
@export var rng_seed := 0
## Permanent modifiers of each player unit (levels, runes), parallel to `players`.
var player_modifiers: Array = []
## False once setup() was called: the Game root owns what happens after the battle.
var standalone := true
## Starting HP per player (-1: full), from a run.
var player_hp: Array = []
## Stalemate safety net (0: off); see Battle.sudden_death_round.
var sudden_death_round := 0
var sudden_death_percent := 10
## Shown before the round number in the HUD (e.g. "Floor 3").
var battle_title := ""
## The heroes' levels, parallel to `players` (shown in the HUD cards); empty: not shown.
var player_levels: Array = []
## The first-run hints (null: none) and the id of the one to show when the battle opens ("" for none).
var hints: Hints
var opening_tip := ""
var _tip_id := ""
var _sudden_death_announced := false

var battle: Battle
## The seed of the current battle; set rng_seed to it to replay a battle.
var battle_seed := 0
var input_state := State.ENDED
var selected_spell := -1

var _hovered_cell := BoardView.NO_CELL
var _reach: Movement.Reach
var _targetable: Dictionary[Vector2i, bool] = {}
## The hero selected for placement (a unit id), or -1.
var _placing_hero := -1
## The unit whose card is pinned (a unit id), or -1; only the card's ✕ or Esc unpins.
var _pinned_unit := -1
## What the HUD displays, following the played events (see HudModel).
var _hud_model: HudModel
## The unit whose turn-order chip the mouse is over, or -1: its cell counts as hovered.
var _chip_unit := -1
## A left press started on the board (not on the HUD): its release may be a click.
var _board_press := false
## The cell under the press, to compare with the one under the release.
var _press_cell := BoardView.NO_CELL
## Bumped by each new battle; coroutines of an abandoned battle stop after their awaits.
var _battle_generation := 0

@onready var camera_rig: CameraRig = $CameraRig
@onready var board_view: BoardView = $BoardView
@onready var units_view: UnitsView = $UnitsView
@onready var event_player: EventPlayer = $EventPlayer
@onready var hud: Hud = $Hud


## Injects a battle. Call before the controller enters the tree (its _ready starts it).
## `hero_hp`: starting HP per player (-1: full); `title`: shown in the HUD (e.g. "Floor 3").
func setup(battle_encounter: Encounter, player_units: Array[UnitData], modifiers: Array, battle_rng_seed := 0,
		hero_hp: Array = [], death_round := 0, death_percent := 10, title := "", levels: Array = []) -> void:
	encounter = battle_encounter
	players = player_units
	player_modifiers = modifiers
	rng_seed = battle_rng_seed
	player_hp = hero_hp
	sudden_death_round = death_round
	sudden_death_percent = death_percent
	battle_title = title
	player_levels = levels
	standalone = false


## The player's settings (battle speed, auto end turn); the Game root hands in its own, edited in
## place. A standalone battle uses the defaults.
var settings := Settings.new()
## A QA battle (from the QA screen): the cheat bar is offered; nothing of it is saved.
var qa_battle := false
## QA tools: the AI plays the heroes (EnemyAI is team-agnostic) until switched off.
var auto_play := false
## The guided first steps (null: none, as in a standalone battle); the Game root hands it in.
var tutorial: Tutorial
var _step: Dictionary = {}
## Whether this controller set Engine.time_scale (so it gives it back).
var _set_time_scale := false


func _exit_tree() -> void:
	if _set_time_scale:
		Engine.time_scale = 1.0


## Puts the settings' battle speed into effect: fast speeds the whole scene up (the rules never
## look at the clock), instant makes the event player skip its animations.
func apply_battle_speed() -> void:
	hud.set_battle_speed(settings.battle_speed)
	event_player.instant = settings.battle_speed == Settings.BattleSpeed.INSTANT
	if settings.battle_speed == Settings.BattleSpeed.FAST:
		Engine.time_scale = FAST_TIME_SCALE
		_set_time_scale = true
	elif _set_time_scale:
		Engine.time_scale = 1.0
		_set_time_scale = false


## The HUD button: normal, fast, instant, normal...
func cycle_battle_speed() -> void:
	settings.battle_speed = ((settings.battle_speed + 1) % Settings.BattleSpeed.size()) as Settings.BattleSpeed
	apply_battle_speed()
	speed_changed.emit()


func _ready() -> void:
	if OS.has_feature("web"):
		$DirectionalLight3D.light_energy *= WEB_LIGHT_SCALE
		$WorldEnvironment.environment.ambient_light_energy *= WEB_LIGHT_SCALE
	# The light turns with the camera, so the shadows fall the same way on screen from every
	# side (a fixed light made them look different, even broken, as the camera turned).
	$DirectionalLight3D.reparent(camera_rig)
	hud.spell_selected.connect(select_spell)
	hud.end_turn_pressed.connect(end_turn)
	hud.view_toggle_pressed.connect(func() -> void: camera_rig.set_overhead(not camera_rig.overhead))
	hud.restart_pressed.connect(_on_result_action)
	hud.card_closed.connect(unpin)
	hud.hint_dismissed.connect(_on_tip_dismissed)
	hud.leave_confirmed.connect(left_battle.emit)
	hud.recenter_pressed.connect(recenter)
	hud.speed_pressed.connect(cycle_battle_speed)
	hud.auto_toggled.connect(set_auto_play)
	hud.qa_cheat.connect(qa_cheat)
	hud.tutorial_skipped.connect(_skip_tutorial)
	apply_battle_speed()
	hud.set_leave_available(not standalone)
	hud.chip_hovered.connect(_on_chip_hovered)
	hud.chip_unhovered.connect(_on_chip_unhovered)
	hud.chip_pressed.connect(_on_chip_pressed)
	hud.set_result_action_text("Play again" if standalone else "Continue")
	camera_rig.overhead_changed.connect(hud.set_overhead_view)
	event_player.event_played.connect(_on_event_played)
	event_player.sound.connect(sound.emit)
	start_battle()


## Builds a fresh battle from the encounter and the players, and starts it.
## Returns false (and changes nothing) if the encounter or teams are invalid.
func start_battle() -> bool:
	var battle_state := _create_battle_state()
	if battle_state == null:
		return false  # Whoever made it reported why.
	event_player.stop()  # Abandon the previous battle's playback, if any.
	_battle_generation += 1
	battle = Battle.new(battle_state)
	battle.sudden_death_round = sudden_death_round
	battle.sudden_death_percent = sudden_death_percent
	_sudden_death_announced = false
	selected_spell = -1
	board_view.build(battle_state.grid)
	units_view.build(battle_state, board_view)
	event_player.setup(units_view, board_view, camera_rig)
	camera_rig.set_bounds(Rect2(Vector2.ZERO, Vector2(battle_state.grid.size - Vector2i.ONE) * BoardView.CELL_SIZE))
	camera_rig.fit_board(battle_state.grid.size)
	# A third of the way to the start zone: on a big board the heroes stay clear of the HUD.
	var zone_center := _spawn_center(_placement_zone_for_camera(battle_state))
	camera_rig.focus(board_view.center().lerp(zone_center, START_FOCUS_TOWARD_ZONE))
	camera_rig.face_toward(zone_center - board_view.center())
	hud.hide_result()
	_placing_hero = -1
	_pinned_unit = -1
	_chip_unit = -1
	_refresh_hud()
	_set_state(State.PLACING)
	if not opening_tip.is_empty():
		_show_tip(opening_tip, _unit_spotlight(_first_enemy_id()))  # The elite or boss opens the enemy list.
	return true


## The state of the battle about to start, from the encounter and the players; null (with an error) if they
## are invalid. The multiplayer controller overrides it with the match's.
func _create_battle_state() -> BattleState:
	if encounter == null or encounter.map == null:
		push_error("Battle: no encounter or map set")
		return null
	var errors := encounter.get_validation_errors()
	if not errors.is_empty():
		push_error("Battle: invalid encounter: %s" % "; ".join(errors))
		return null
	var parsed := encounter.map.parse()
	var builds := encounter.builds()
	var enemies: Array[UnitData] = []
	for build in builds:
		enemies.append(build.unit)
	var new_seed := rng_seed if rng_seed != 0 else randi()
	battle_seed = new_seed
	return BattleState.create(parsed, players, enemies, new_seed, player_modifiers, builds, player_hp)


## The cells the camera starts toward (the heroes' start zone).
func _placement_zone_for_camera(battle_state: BattleState) -> Array[Vector2i]:
	return battle_state.zone


## The cells to show as the start zone while heroes are placed.
func _placement_zone() -> Array[Vector2i]:
	return battle.state.zone


## Auto (QA tools): the AI plays the heroes from their next decision on; switched off, the
## player takes over at the next hero turn (or at once, between two of the AI's actions).
func set_auto_play(on: bool) -> void:
	auto_play = on
	hud.set_auto(on)
	if on and input_state in [State.IDLE, State.TARGETING] and battle.state.current_unit().team == UnitState.Team.PLAYER:
		selected_spell = -1
		_set_state(State.ENEMY_TURN)
		_run_enemy_action()


## Whether Auto may be offered: QA tools on, and no tutorial step waiting for the player.
func _auto_available() -> bool:
	return settings.qa_tools and (tutorial == null or tutorial.next_step(Tutorial.BATTLE_STEPS).is_empty())


## QA battles' cheats, on the player's turn: win, lose, kill the pinned unit, heal the
## heroes, refill the acting hero's AP and MP.
func qa_cheat(action: StringName) -> void:
	if not qa_battle or not input_state in [State.IDLE, State.TARGETING]:
		return
	var events: Array[BattleEvents.Event] = []
	match action:
		&"win", &"lose":
			var team := UnitState.Team.ENEMY if action == &"win" else UnitState.Team.PLAYER
			for unit in battle.state.units:
				if unit.team == team:
					events.append_array(battle.qa_set_hp(unit.id, 0))
		&"kill":
			if _pinned_unit != -1:
				events.append_array(battle.qa_set_hp(_pinned_unit, 0))
		&"heal":
			for unit in battle.state.units:
				if unit.team == UnitState.Team.PLAYER:
					events.append_array(battle.qa_set_hp(unit.id, unit.max_hp()))
		&"refill":
			var unit := battle.state.current_unit()
			unit.ap = unit.max_ap()
			unit.mp = unit.max_mp()
			unit.commit_position()
			_refresh_hud()
			_enter_idle()
			return
	if not events.is_empty():
		_play(events)


## Abandons the current battle (even mid-animation) and starts a new one.
func restart() -> void:
	start_battle()


func _on_result_action() -> void:
	if standalone:
		restart()
	else:
		battle_finished.emit(battle.state)


# --- Player commands (from the HUD and board clicks) ---

## Selects a spell to aim, or unselects it if it's already selected.
func select_spell(index: int) -> void:
	if input_state != State.IDLE and input_state != State.TARGETING:
		return
	var unit := battle.state.current_unit()
	if index == selected_spell or not BattleActions.CastSpell.can_afford(unit, index):
		_enter_idle()
		return
	if not Tutorial.allows(_step, Tutorial.Action.SELECT_SPELL):
		return
	selected_spell = index
	_tutorial_done(Tutorial.Action.SELECT_SPELL)
	_set_state(State.TARGETING)


## Esc / right click: closes the leave confirmation or the order overlay, else stops aiming, else deselects the hero
## being placed, else unpins the card.
func cancel() -> void:
	if hud.close_leave_panel() or hud.close_order_overlay():
		return
	if input_state == State.TARGETING:
		_enter_idle()
	elif input_state == State.PLACING and _placing_hero != -1:
		_placing_hero = -1
		_set_state(State.PLACING)
	else:
		unpin()


## Pins a unit's card on the right; it stays until unpinned, even when the mouse leaves.
func pin(unit_id: int) -> void:
	if unit_id == _pinned_unit:
		return
	_pinned_unit = unit_id
	_update_inspected()


func unpin() -> void:
	if _pinned_unit != -1:
		_pinned_unit = -1
		_update_inspected()


## Ends the turn, or ends placement and starts the fight.
func end_turn() -> void:
	if input_state == State.PLACING:
		if not Tutorial.allows(_step, Tutorial.Action.READY):
			return
		_placing_hero = -1
		_tutorial_done(Tutorial.Action.READY)
		_play(battle.start())
	elif input_state == State.IDLE or input_state == State.TARGETING:
		if not Tutorial.allows(_step, Tutorial.Action.END_TURN):
			return
		_perform(BattleActions.EndTurn.new(battle.state.current_unit().id))


## A click on a board cell (or on a unit standing there).
func click_cell(cell: Vector2i) -> void:
	var unit_id := battle.state.current_unit().id if battle != null else -1
	var clicked := battle.state.unit_at(cell) if battle != null else null
	# A click that casts, moves or places is that action only; one that does nothing else pins the
	# unit under it (to look at it).
	var action := _click_action(cell, clicked)
	if clicked != null and clicked.id != _active_card_unit_id() and action == -1:
		pin(clicked.id)
	if action != -1 and not Tutorial.allows(_step, action as Tutorial.Action):
		return  # The tutorial lets only the step's own action through.
	match input_state:
		State.PLACING:
			# Select a hero, then a zone cell (a hero there swaps); the selected hero again deselects.
			var unit := battle.state.unit_at(cell)
			if _placing_hero == -1:
				if unit != null and unit.team == UnitState.Team.PLAYER:
					_placing_hero = unit.id
					_refresh_hud()
					_set_state(State.PLACING)
			elif unit != null and unit.id == _placing_hero:
				cancel()
			elif cell in battle.state.zone:
				var hero := _placing_hero
				_placing_hero = -1
				_perform(BattleActions.Place.new(hero, cell))
		State.IDLE:
			if _reach != null and _reach.can_reach(cell):
				_perform(BattleActions.Move.new(unit_id, cell))
		State.TARGETING:
			if _targetable.has(cell):
				_perform(BattleActions.CastSpell.new(unit_id, selected_spell, cell))


## What a click on `cell` (with `clicked` on it) does in the current state, as a Tutorial.Action:
## picks or places a hero, moves, or casts; -1 when it does nothing.
func _click_action(cell: Vector2i, clicked: UnitState) -> int:
	match input_state:
		State.PLACING:
			if _placing_hero == -1:
				return Tutorial.Action.PLACE if clicked != null and clicked.team == UnitState.Team.PLAYER else -1
			return Tutorial.Action.PLACE if cell in battle.state.zone or (clicked != null and clicked.id == _placing_hero) else -1
		State.IDLE:
			return Tutorial.Action.MOVE if _reach != null and _reach.can_reach(cell) else -1
		State.TARGETING:
			return Tutorial.Action.CAST if _targetable.has(cell) else -1
	return -1


# --- Input ---

## Right click over a HUD control stops aiming too: the control eats the click before
## _unhandled_input would see it.
func _input(event: InputEvent) -> void:
	if input_state == State.TARGETING and event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_RIGHT and get_viewport().gui_get_hovered_control() != null:
		cancel()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"cancel"):
		cancel()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"camera_recenter"):
		recenter()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		# A click acts on release, unless the press turned into a camera drag; a press the HUD
		# ate never reaches here, so its release can't click the board.
		if event.pressed:
			_board_press = true
			_press_cell = board_view.pick_cell(camera_rig.camera, event.position)
		elif _board_press:
			_board_press = false
			# Only a release on the cell that was pressed, over the board, after no drag: a release
			# over the HUD, or after the camera slid under the cursor, is not a click.
			if not camera_rig.dragged and get_viewport().gui_get_hovered_control() == null:
				var cell := board_view.pick_cell(camera_rig.camera, event.position)
				if cell != BoardView.NO_CELL and cell == _press_cell:
					click_cell(cell)
					get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not _step.is_empty():
		hud.update_tutorial_area(_tutorial_rect(_step["spot"]))  # The camera may be moving; the HUD settles after its first frame.


## Hover is re-picked every physics frame from the mouse position, so it also follows
## camera turns and zooms; highlights only change when the hovered cell does.
func _physics_process(_delta: float) -> void:
	camera_rig.pan_enabled = not hud.is_modal_open()  # Arrow keys drive the menus over the board.
	if board_view.grid == null:
		return
	var cell := _hover_cell(get_viewport().gui_get_hovered_control(), get_viewport().get_mouse_position())
	if cell != _hovered_cell:
		_hovered_cell = cell
		_update_hover()
	_update_see_through()


## Obstacles that hide a living unit from the camera fade. (Not the hovered cell: the mouse only
## ever picks what is in front, so fading for it just made rocks vanish at random.)
func _update_see_through() -> void:
	if camera_rig.camera == null or battle == null:
		return
	var targets: Array[Vector3] = []
	for unit in battle.state.units:
		var view := units_view.find_view(unit.id)
		if unit.is_alive() and view != null:
			# The feet are what a rock hides first, the middle what a taller thing would.
			targets.append(view.global_position + Vector3.UP * 0.15)
			targets.append(view.global_position + Vector3.UP * view.world_height() * 0.5)
	board_view.look_through(camera_rig.camera.global_position, targets)


## The cell the mouse designates: none over the HUD, except over the inspect panel, where
## the hover sticks (so the panel stays up and its tooltips can be read).
func _hover_cell(hovered_control: Control, mouse_position: Vector2) -> Vector2i:
	if _chip_unit != -1 and battle != null:
		return battle.state.units[_chip_unit].cell
	if hovered_control != null:
		return _hovered_cell if hud.is_inspect_control(hovered_control) else BoardView.NO_CELL
	return board_view.pick_cell(camera_rig.camera, mouse_position)


func _on_chip_hovered(unit_id: int) -> void:
	_chip_unit = unit_id if battle != null and unit_id >= 0 and unit_id < battle.state.units.size() else -1


func _on_chip_unhovered() -> void:
	_chip_unit = -1


## Clicking a turn-order chip moves the camera to its unit.
func _on_chip_pressed(unit_id: int) -> void:
	focus_unit(unit_id)


## Slides the camera to a unit, where it is drawn right now (the state is already final while
## events play, so a unit's cell would be where it will end up).
func focus_unit(unit_id: int) -> void:
	if battle == null or unit_id < 0 or unit_id >= battle.state.units.size():
		return
	var view := units_view.find_view(unit_id)
	var point := view.position if view != null else board_view.cell_to_world(battle.state.units[unit_id].cell)
	camera_rig.focus_on(point)


## The camera at a turn's start: an ally's turn always centers on it; an enemy's turn moves the
## camera only when the enemy isn't comfortably on screen already (and then slowly), so a run
## of enemy turns in view doesn't make the view dart between them.
func _focus_turn_start(unit_id: int) -> void:
	if battle == null or unit_id < 0 or unit_id >= battle.state.units.size():
		return
	if battle.state.units[unit_id].team == UnitState.Team.PLAYER:
		focus_unit(unit_id)
		return
	var view := units_view.find_view(unit_id)
	var point := view.position if view != null else board_view.cell_to_world(battle.state.units[unit_id].cell)
	if not camera_rig.is_on_screen([point] as Array[Vector3]):
		camera_rig.focus_on(point, true, ENEMY_FOCUS_DURATION)


## Back to the acting unit (the Recenter key and button).
func recenter() -> void:
	if battle != null and battle.state.started and _hud_model.current_id != -1:
		focus_unit(_hud_model.current_id)  # The acting unit on screen: the state is already final while events play.
	elif battle != null:
		camera_rig.focus_on(board_view.center())


# --- Turn loop ---

func _perform(action: BattleActions.Action) -> void:
	var result := battle.perform(action)
	if not result.ok():
		push_warning("Battle: %s" % result.error)  # A UI bug; the state is unchanged.
		return
	if action is BattleActions.Move:
		_tutorial_done(Tutorial.Action.MOVE)
	elif action is BattleActions.CastSpell:
		_tutorial_done(Tutorial.Action.CAST)
	elif action is BattleActions.EndTurn and battle.state.units[action.actor_id].team == UnitState.Team.PLAYER:
		_tutorial_done(Tutorial.Action.END_TURN)
	_play(result.events)


func _play(events: Array[BattleEvents.Event]) -> void:
	var generation := _battle_generation
	_set_state(State.ANIMATING)
	await event_player.play(events)
	if generation != _battle_generation:
		return  # This battle was abandoned while its events played.
	units_view.sync(battle.state)
	_begin_next()


## Decides what happens after a playback: result, player's input, or the AI's next action.
func _begin_next() -> void:
	var battle_state := battle.state
	_refresh_hud()
	if not battle_state.started:
		_set_state(State.PLACING)
		return
	units_view.set_active(battle_state.current_unit().id if not battle_state.is_over() else -1)
	if battle_state.is_over():
		_set_state(State.ENDED)
		# A mutual wipe (DRAW) is shown as a defeat (decision record).
		var won := battle_state.outcome() == BattleState.Outcome.PLAYER_WON
		sound.emit(&"victory" if won else &"defeat")
		_cheer(UnitState.Team.PLAYER if won else UnitState.Team.ENEMY, battle_state)
		hud.show_result(won, battle_seed)
		battle_ended.emit(battle_state)
		return
	if battle_state.current_unit().team == UnitState.Team.PLAYER and not auto_play:
		_enter_idle()
	else:
		_set_state(State.ENEMY_TURN)
		_run_enemy_action()


func _run_enemy_action() -> void:
	var generation := _battle_generation
	if event_player.instant:
		await get_tree().process_frame
	else:
		await create_tween().tween_interval(ENEMY_ACTION_DELAY).finished
	if generation != _battle_generation:
		return
	var unit_id := battle.state.current_unit().id
	var result := battle.perform(EnemyAI.choose_next(battle.state, unit_id, _ai_profile_for(battle.state.units[unit_id])))
	if not result.ok():
		push_error("Battle: AI chose an invalid action: %s" % result.error)
		result = battle.perform(BattleActions.EndTurn.new(unit_id))
	_play(result.events)


## The unit's own profile (its preset), else the encounter's, else the fallback.
func _ai_profile_for(unit: UnitState) -> AIProfile:
	if unit.ai_profile != null:
		return unit.ai_profile
	return encounter.ai_profile if encounter.ai_profile != null else ai_profile


## The survivors of the winning team play their victory animation (heroes after a win, the
## enemies after a loss), over the fanfare.
func _cheer(winners: UnitState.Team, state: BattleState) -> void:
	for unit in state.units:
		if unit.team == winners and unit.is_alive():
			var view := units_view.find_view(unit.id)
			if view != null:
				view.play_victory()


## Shows a one-time tip card (not while a tutorial step is up, and never twice), lighting
## the screen area `spotlight` returns (none by default).
func _show_tip(id: String, spotlight := Callable()) -> void:
	if hints == null or not hints.should_show(id) or hud.is_tutorial_active():
		return
	_tip_id = id
	hud.show_hint(hints.text(id), spotlight)


## A spotlight on a unit (feet to head), followed as it moves.
func _unit_spotlight(unit_id: int) -> Callable:
	return func() -> Rect2: return _unit_screen_rect(unit_id)


## A spotlight on the status icons above a unit.
func _status_spotlight(unit_id: int) -> Callable:
	return func() -> Rect2:
		var view := units_view.find_view(unit_id)
		return view.status_row_rect(camera_rig.camera) if view != null and camera_rig.camera != null else Rect2()


func _first_enemy_id() -> int:
	for unit in battle.state.units:
		if unit.team == UnitState.Team.ENEMY:
			return unit.id
	return -1


## The screen rectangle around a unit as drawn right now, feet to head (empty if it has no view).
func _unit_screen_rect(unit_id: int) -> Rect2:
	var view := units_view.find_view(unit_id)
	if view == null or camera_rig.camera == null:
		return Rect2()
	var feet := camera_rig.camera.unproject_position(view.global_position)
	var head := camera_rig.camera.unproject_position(view.global_position + Vector3.UP * view.world_height())
	var height := absf(feet.y - head.y)
	return Rect2(Vector2(feet.x - height * 0.4, minf(feet.y, head.y)), Vector2(height * 0.8, height))


func _on_tip_dismissed() -> void:
	if hints != null and not _tip_id.is_empty():
		hints.dismiss(_tip_id)
		_tip_id = ""
		tutorial_changed.emit()  # The Game root saves the settings.


func _on_event_played(event: BattleEvents.Event) -> void:
	if event is BattleEvents.StatusApplied:
		_show_tip("first_status", _status_spotlight((event as BattleEvents.StatusApplied).unit_id))
	_hud_model.apply(event)
	_show_turn()
	if event is BattleEvents.TurnStarted:
		_focus_turn_start((event as BattleEvents.TurnStarted).unit_id)  # Every turn, ally or enemy: the camera follows the action.
	if event is BattleEvents.TurnStarted and battle.is_sudden_death() and not _sudden_death_announced:
		_sudden_death_announced = true
		if battle.state.pvp:
			hud.show_banner(tr("Sudden death: every hero loses %d%% HP every turn") % sudden_death_percent)
		else:
			hud.show_banner(tr("Sudden death: the party loses %d%% HP every turn") % sudden_death_percent)
		return
	if event is BattleEvents.TurnStarted:
		var unit := battle.state.units[(event as BattleEvents.TurnStarted).unit_id]
		if unit.team == UnitState.Team.PLAYER:
			sound.emit(&"turn_start")
		hud.show_banner(tr("%s's turn") % _turn_banner_name(unit))



## Who the turn banner names: the unit's own name (multiplayer names the player instead).
func _turn_banner_name(unit: UnitState) -> String:
	return tr(unit.data.display_name)


# --- State and highlights ---

func _enter_idle() -> void:
	selected_spell = -1
	_set_state(State.IDLE)


func _set_state(new_state: State) -> void:
	input_state = new_state
	var player_turn := new_state == State.IDLE or new_state == State.TARGETING or new_state == State.PLACING
	hud.set_player_controls_enabled(player_turn)
	hud.set_placing(new_state == State.PLACING)
	hud.show_qa_controls(_auto_available(), qa_battle and new_state != State.ENDED,
			new_state == State.IDLE or new_state == State.TARGETING)
	hud.set_selected_spell(selected_spell if new_state == State.TARGETING else -1)
	board_view.clear_highlights()
	units_view.clear_previews()
	_reach = null
	_targetable.clear()
	var unit_id := battle.state.current_unit().id if battle != null and not battle.state.is_over() else -1
	match new_state:
		State.PLACING:
			units_view.set_active(_placing_hero)
			board_view.show_highlight(BoardView.Highlight.ZONE, _placement_zone())
		State.IDLE:
			_reach = Movement.reach(battle.state, unit_id)
			board_view.show_highlight(BoardView.Highlight.REACH, _reach.cells())
		State.TARGETING:
			var spell := battle.state.units[unit_id].data.spells[selected_spell]
			var cells := Targeting.targetable_cells(battle.state, unit_id, spell)
			for cell in cells:
				_targetable[cell] = true
			board_view.show_highlight(BoardView.Highlight.RANGE, cells)
			board_view.show_highlight(BoardView.Highlight.RANGE_BLOCKED,
					Targeting.blocked_cells(battle.state, unit_id, spell))
	hud.set_prompt(_prompt_text())
	hud.set_end_turn_pulse(new_state == State.IDLE and _nothing_left_to_do())
	if new_state == State.IDLE and settings.auto_end_turn and _nothing_left_to_do():
		_end_turn_soon()
	_refresh_tutorial()
	_update_hover()


## Marks the current tutorial step done when the player did what it waits for.
func _tutorial_done(action: Tutorial.Action) -> void:
	if tutorial != null and not _step.is_empty() and _step["awaits"] == action:
		tutorial.complete(_step["id"])
		_step = {}
		hud.hide_tutorial()
		tutorial_changed.emit()


## Shows the first step not done, when the state is the one it is about; steps that can't apply
## (a hero who can't move) are skipped as done.
func _refresh_tutorial() -> void:
	_step = {}
	if tutorial == null or battle == null or battle.state.is_over():
		hud.hide_tutorial()
		return
	for guard in Tutorial.BATTLE_STEPS.size():
		var step := tutorial.next_step(Tutorial.BATTLE_STEPS)
		if step.is_empty() or not _tutorial_can_show(step):
			if not step.is_empty() and _tutorial_obsolete(step):
				tutorial.complete(step["id"])
				tutorial_changed.emit()
				continue
			hud.hide_tutorial()
			return
		_step = step
		hud.show_tutorial_step(Tutorial.text_of(step), _tutorial_rect(step["spot"]))
		return
	hud.hide_tutorial()


## The step's moment has come: the state it talks about.
func _tutorial_can_show(step: Dictionary) -> bool:
	match step["awaits"]:
		Tutorial.Action.READY: return input_state == State.PLACING
		Tutorial.Action.MOVE: return input_state == State.IDLE and _reach != null and not _reach.cells().is_empty()
		Tutorial.Action.SELECT_SPELL: return input_state == State.IDLE and _can_cast_any()
		Tutorial.Action.CAST: return input_state == State.TARGETING and not _targetable.is_empty()
		Tutorial.Action.END_TURN: return input_state == State.IDLE
	return false


## The step can never apply this turn (the hero can't move or cast): it counts as done.
func _tutorial_obsolete(step: Dictionary) -> bool:
	if input_state != State.IDLE:
		return false
	match step["awaits"]:
		Tutorial.Action.MOVE: return _reach != null and _reach.cells().is_empty()
		Tutorial.Action.SELECT_SPELL: return not _can_cast_any()
	return false


func _can_cast_any() -> bool:
	var unit := battle.state.current_unit()
	for slot in unit.data.spells.size():
		if BattleActions.CastSpell.can_afford(unit, slot):
			return true
	return false


func _skip_tutorial() -> void:
	if tutorial != null:
		tutorial.skip_all()
		_step = {}
		hud.hide_tutorial()
		tutorial_changed.emit()


## Screen rectangle of what a step lights.
func _tutorial_rect(spot: Tutorial.Spot) -> Rect2:
	match spot:
		Tutorial.Spot.READY_BUTTON, Tutorial.Spot.END_TURN_BUTTON: return hud.end_turn_rect()
		Tutorial.Spot.SPELL_BAR: return hud.spell_slots_rect()
		Tutorial.Spot.REACH: return _screen_rect_of(_reach.cells() if _reach != null else [] as Array[Vector2i])
		Tutorial.Spot.TARGETS: return _screen_rect_of(_targetable.keys() as Array[Vector2i] if not _targetable.is_empty() else [] as Array[Vector2i])
	return Rect2()


## The screen rectangle around the top faces of board cells.
func _screen_rect_of(cells: Array[Vector2i]) -> Rect2:
	var box := Rect2()
	var first := true
	for cell in cells:
		var center := board_view.cell_to_world(cell)
		for corner in [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(-0.5, 0.5), Vector2(0.5, 0.5)]:
			var point := camera_rig.camera.unproject_position(center + Vector3(corner.x, 0.0, corner.y) * BoardView.CELL_SIZE)
			box = Rect2(point, Vector2.ZERO) if first else box.expand(point)
			first = false
	return box


## Auto end turn: ends the turn after a short pause, if the hero still has nothing to do then.
func _end_turn_soon() -> void:
	var generation := _battle_generation
	var turn := battle.state.current_unit().id
	if event_player.instant:
		await get_tree().process_frame
	else:
		await create_tween().tween_interval(AUTO_END_DELAY).finished
	# While a tutorial step is up the player follows it: the step's own card must be readable.
	if generation == _battle_generation and input_state == State.IDLE and battle.state.current_unit().id == turn \
			and not battle.state.is_over() and _nothing_left_to_do() and _step.is_empty():
		end_turn()


## The guidance line for the current step.
func _prompt_text() -> String:
	match input_state:
		State.PLACING:
			if _placing_hero == -1:
				return tr("Place your heroes: click one, then a teal cell. Ready (%s) to fight") % SettingsApplier.key_text(&"end_turn")
			return tr("Click a teal cell to place %s (Esc to deselect)") % tr(battle.state.units[_placing_hero].label)
		State.IDLE:
			if _nothing_left_to_do():
				return tr("Nothing left to do: end your turn (%s)") % SettingsApplier.key_text(&"end_turn")
			return tr("Move to a blue cell or pick a spell (%s)") % _spell_keys_text(battle.state.current_unit().data.spells.size())
		State.TARGETING:
			var spell_name := tr(battle.state.current_unit().data.spells[selected_spell].display_name)
			if _targetable.is_empty():
				return tr("%s has no target from here (its reach is shaded). Esc to cancel") % spell_name
			return tr("Choose a target for %s (orange cells). Esc to cancel") % spell_name
		State.ENEMY_TURN:
			return tr("%s is acting...") % tr(battle.state.current_unit().label)
	return ""


## The keys of the spell slots, e.g. "1-3", or "1" for one spell.
func _spell_keys_text(spell_count: int) -> String:
	var count := clampi(spell_count, 1, SpellBar.MAX_KEYED_SLOTS)
	var first := SettingsApplier.key_text(&"spell_1")
	return first if count == 1 else "%s-%s" % [first, SettingsApplier.key_text(StringName("spell_%d" % count))]


## The acting hero can't afford any spell and has no MP left (repositioning back alone
## wouldn't help).
func _nothing_left_to_do() -> bool:
	var unit := battle.state.current_unit()
	if unit.mp > 0 and _reach != null and not _reach.cells().is_empty():
		return false
	for slot in unit.data.spells.size():
		if BattleActions.CastSpell.can_afford(unit, slot):
			return false
	return true


## Path to the hovered cell while moving, or the spell's area while aiming; in any state,
## the hovered unit (other than the one acting) in the HUD's inspect panel.
func _update_hover() -> void:
	_update_inspected()
	var cells: Array[Vector2i] = []
	match input_state:
		State.PLACING:
			if _placing_hero != -1:
				cells.append(battle.state.units[_placing_hero].cell)
				if _hovered_cell in battle.state.zone:
					cells.append(_hovered_cell)
			board_view.show_highlight(BoardView.Highlight.PATH, cells)
		State.IDLE:
			board_view.clear_path_cost()
			if _reach != null and _reach.can_reach(_hovered_cell):
				# The walk from where the hero stands; the cost counts from where its move started.
				var unit_id := battle.state.current_unit().id
				cells = Movement.walk_path(battle.state, unit_id, _hovered_cell) \
						if _reach.origin != _reach.standing else _reach.path_to(_hovered_cell)
				board_view.show_path_cost(_hovered_cell, _reach.cost_to(_hovered_cell),
						Movement.climbing_steps(battle.state.grid, _reach.standing, cells))
			board_view.show_highlight(BoardView.Highlight.PATH, cells)
		State.TARGETING:
			if _targetable.has(_hovered_cell):
				var caster := battle.state.current_unit()
				var spell := caster.data.spells[selected_spell]
				cells = Targeting.area_cells(battle.state.grid, spell.area, caster.cell, _hovered_cell)
				units_view.show_previews(DamagePreview.for_cast(battle.state, caster.id, selected_spell, _hovered_cell))
				var landings: Array[Vector2i] = []
				landings.assign(DamagePreview.landings(battle.state, caster.id, selected_spell, _hovered_cell).values())
				board_view.show_highlight(BoardView.Highlight.LANDING, landings)
			else:
				units_view.clear_previews()
				board_view.clear_highlight(BoardView.Highlight.LANDING)
			board_view.show_highlight(BoardView.Highlight.AREA, cells)
		# Other states: _set_state already cleared the hover highlights, and the AREA layer
		# may be showing a cast's flash from the EventPlayer, which hover must not touch.
	if _chip_unit != -1 and input_state in [State.PLACING, State.IDLE, State.TARGETING]:
		board_view.show_highlight(BoardView.Highlight.PATH, [battle.state.units[_chip_unit].cell] as Array[Vector2i])


## The right-hand card: the hovered unit, else the pinned one (with its ✕). The unit on
## the active card is never repeated there.
func _update_inspected() -> void:
	var shown: UnitInfo = null
	var pinned := false
	if battle != null and _pinned_unit != -1 and _hud_model.infos[_pinned_unit].hp <= 0:
		_pinned_unit = -1  # A fallen unit's card goes away.
	if battle != null:
		var active_id := _active_card_unit_id()
		if _hovered_cell != BoardView.NO_CELL:
			var hovered := battle.state.unit_at(_hovered_cell)
			if hovered != null and hovered.id != active_id:
				shown = _hud_model.infos[hovered.id]
		if shown == null and _pinned_unit != -1 and _pinned_unit != active_id:
			shown = _hud_model.infos[_pinned_unit]
		pinned = shown != null and shown.unit_id == _pinned_unit
	if shown == null:
		hud.hide_inspected()
	else:
		hud.set_inspect_side(_unit_is_right_of_center(shown.unit_id))
		hud.show_inspected(shown, pinned)


## Whether a unit is drawn in the right half of the screen, where the inspect card would
## sit on top of it: the card goes to the left edge then (and to the right otherwise).
func _unit_is_right_of_center(unit_id: int) -> bool:
	var view := units_view.find_view(unit_id)
	if view == null:
		return false
	var screen_x := camera_rig.camera.unproject_position(units_view.to_global(view.position)).x
	return screen_x > get_viewport().get_visible_rect().size.x * 0.5


## The unit shown on the active card: the acting one, or (placing) the selected hero, else the first.
func _active_card_unit_id() -> int:
	if battle.state.started:
		return _hud_model.current_id
	return _placing_hero if _placing_hero != -1 else battle.state.units[0].id


## Re-syncs the HUD from the battle state: the source of truth, after a playback (or a
## new battle, or a placement) while the events in between only updated the model.
func _refresh_hud() -> void:
	_hud_model = HudModel.from_state(battle.state, player_levels)
	_show_turn()
	var active := _hud_model.infos.get(_active_card_unit_id()) as UnitInfo
	if active != null:
		hud.show_spells(active.spells, active.ap, active.cooldowns)


## Shows the model's turn in the HUD: order, active card, AP for the spell bar, inspect
## card. The HUD gets plain UnitInfo values, never state.
func _show_turn() -> void:
	hud.show_turn_order(_hud_model.upcoming(), _hud_model.round_number, battle_title)
	var active := _hud_model.infos.get(_active_card_unit_id()) as UnitInfo
	if active != null:
		hud.show_unit(active)
		hud.set_spell_ap(active.ap)
		hud.set_spell_cooldowns(active.cooldowns)
	_update_inspected()


func _spawn_center(spawns: Array[Vector2i]) -> Vector3:
	var sum := Vector3.ZERO
	for cell in spawns:
		sum += board_view.cell_to_world(cell)
	return sum / maxi(spawns.size(), 1)
