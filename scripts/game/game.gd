class_name Game
extends Node
## The game's root: owns the profile and its save, and swaps its one child screen between
## the party screen (the hub), a battle and the run screen between floors. The run's rules
## are RunDirector's: this root asks it for the next battle, hands it each result and boss
## choice, saves the profile after every step (so a run resumes at the next floor) and shows
## the report. No global state: everything a screen needs is passed to it (calls down,
## signals up).

## The game's name, shown on the title screen.
const TITLE := "Rune Ascent"
const TITLE_SCENE := preload("res://scenes/game/title_screen.tscn")
const SETTINGS_SCENE := preload("res://scenes/game/settings_screen.tscn")
const START_SCENE := preload("res://scenes/game/start_screen.tscn")
const ACHIEVEMENTS_SCENE := preload("res://scenes/game/achievements_screen.tscn")
const SPELLS_SCENE := preload("res://scenes/game/spells_screen.tscn")
const QA_SCENE := preload("res://scenes/game/qa_screen.tscn")
const CREDITS_SCENE := preload("res://scenes/game/credits_screen.tscn")
const PARTY_SCENE := preload("res://scenes/game/party_screen.tscn")
const RUN_SCENE := preload("res://scenes/game/run_screen.tscn")
const BATTLE_SCENE := preload("res://scenes/battle/battle.tscn")
## Distance of the mute button from the corner of the window.
## The screens' own margins (24 at the sides, 16 at the top): the corner button lines up with their top bars.
const OVERLAY_MARGIN_X := 24.0
const OVERLAY_MARGIN_Y := 16.0
## How long an achievement toast stays.
const TOAST_SECONDS := 3.5
const AUDIO_SET := preload("res://data/audio/audio_set.tres")

@export var roster: Roster
## The tower's floors, boons and stages.
@export var tower: TowerConfig
@export var save_path := SaveStore.DEFAULT_PATH
@export var settings_path := SettingsStore.DEFAULT_PATH
## Ask for a click before the title (browsers keep sound off until one), on every platform so
## the web and desktop versions open the same way; tests turn it off to start on the title.
@export var require_click_to_start := true
## 0 picks a random seed per battle (floors are deterministic anyway; this is the dice).
@export var rng_seed := 0

var profile: Profile
var settings: Settings
## Sounds and music; screens and views only ask it by event name.
var audio: AudioService
## The guided first steps (their progress lives in the settings).
var tutorial: Tutorial
var _mute_button: MuteButton
var _toast: PanelContainer
var _toast_label: Label
var _toast_tween: Tween
var hints: Hints
var screen: Node
var _store: SaveStore
var _settings_store: SettingsStore
## What the last run brought, shown on the hub.
var _summary := ""
## The state whose result was applied, so a battle can't count twice, and its report.
var _applied_state: BattleState
var _report: RunDirector.Report
var _battle_title := ""
## The music of the battle being started: "boss" or "battle".
var _battle_music: StringName = &"battle"
## The hero whose tab the player picked last (kept when the hub is rebuilt).
var _selected_hero := 0
## The title's Play opens multiplayer; false opens the single-player hub that this fork keeps (tests use it).
var play_opens_multiplayer := true
## The QA screen's choices, kept between its visits.
var _qa_state := QaScreen.State.new()


func _ready() -> void:
	_store = SaveStore.new(save_path)
	profile = _store.load_or_create(roster)
	audio = AudioService.new()
	audio.audio_set = AUDIO_SET
	add_child(audio)
	audio.hook_buttons(get_tree())  # Every button clicks.
	_build_overlay()
	_settings_store = SettingsStore.new(settings_path)
	settings = _settings_store.load_or_default()
	hints = Hints.new(settings)
	tutorial = Tutorial.new(settings)
	SettingsApplier.apply(settings, get_window(), false)
	_mute_button.show_muted(settings.muted)
	if WebPage.query("e2e") == "1":  # Browser tests drive the game through this (see E2eHook).
		var hook := E2eHook.new()
		hook.game = self
		add_child(hook)
	if require_click_to_start:
		show_start()
	else:
		_open_first_screen()


## Web only: the click that lets the browser play sound comes before the title.
func show_start() -> void:
	var start := START_SCENE.instantiate() as StartScreen
	_replace_screen(start)
	start.show_title(TITLE)
	start.apply_branding(Branding.title_image())
	start.started.connect(_open_first_screen)


## After the first click: an invite link in the page's address goes straight to joining, anything else to the title.
func _open_first_screen() -> void:
	if _fragment_joins():
		show_multiplayer()
	else:
		show_title()


## The page address carries an invite or a room code to join.
func _fragment_joins() -> bool:
	var fragment := WebPage.fragment()
	return fragment.begins_with(InviteCodec.JOIN_KEY + "=") or fragment.begins_with(RoomCode.LINK_KEY + "=")


## Multiplayer: the front page, joining, the lobby and the fight (NetFlow). Back leaves for the title.
func show_multiplayer() -> void:
	var flow := NetFlow.new()
	flow.settings = settings
	flow.exit_requested.connect(show_title)
	flow.sound.connect(audio.play_sfx)
	flow.speed_changed.connect(_on_settings_changed)
	flow.music_requested.connect(audio.play_music)
	_replace_screen(flow)
	var fragment := WebPage.fragment()
	flow.start(fragment)
	if _fragment_joins():
		WebPage.clear_fragment()


## The first screen. Play opens the hub, where a saved run waits as Continue / Abandon.
func show_title() -> void:
	var title := TITLE_SCENE.instantiate() as TitleScreen
	_replace_screen(title)
	title.show_title(TITLE)
	title.apply_branding(Branding.logo(), Branding.title_image())
	title.show_best_floor(profile.best_depth)
	title.play_pressed.connect(show_multiplayer if play_opens_multiplayer else show_party)
	title.settings_pressed.connect(show_settings)
	title.quit_pressed.connect(get_tree().quit)
	title.show_qa(settings.qa_tools)
	title.qa_pressed.connect(show_qa)


## The QA tools (with the setting on): floors, playground, profile tools. Its choices are kept
## between visits.
func show_qa(message := "") -> void:
	var qa := QA_SCENE.instantiate() as QaScreen
	_replace_screen(qa)
	qa.show_qa(_qa_state, profile, tower, message)
	qa.back_pressed.connect(show_title)
	qa.fight_requested.connect(start_qa_battle)
	qa.profile_action.connect(_on_qa_profile_action)


## A QA battle: the usual battle screen with cheats, whose end (or Menu) returns to the QA
## screen. Nothing of it is applied or saved: no XP, runes, achievements or run progress.
func start_qa_battle(encounter: Encounter, team: QaTools.Team, title: String) -> void:
	if team.units.is_empty():
		show_qa(tr("The quick team has no hero (every level is 0)."))
		return
	var spawns := encounter.map.parse().player_spawns.size()
	if team.units.size() > spawns:
		show_qa(tr("The party needs 1 to %d heroes to fight on this map.") % spawns)
		return
	var battle := BATTLE_SCENE.instantiate() as BattleController
	battle.setup(encounter, team.units, team.modifiers, rng_seed, [], tower.sudden_death_round, tower.sudden_death_percent,
			title, team.levels)
	battle.settings = settings
	battle.qa_battle = true
	battle.sound.connect(audio.play_sfx)
	battle.speed_changed.connect(_on_settings_changed)
	battle.left_battle.connect(show_qa.bind(tr("You left the QA battle.")))
	battle.battle_finished.connect(func(_state: BattleState) -> void: show_qa(tr("QA battle over: nothing was saved.")))
	_battle_music = &"battle"
	_replace_screen(battle)
	if battle.battle == null:
		show_qa(tr("The battle couldn't start (see the log)."))


func _on_qa_profile_action(action: StringName, value: int) -> void:
	var message := ""
	match action:
		&"set_levels":
			QaTools.set_levels(profile, value)
			message = tr("Every hero is now level %d.") % profile.heroes[0].level
		&"give_runes":
			QaTools.give_every_rune(profile, value)
			message = tr("One of every rune, at level %d, is in the stash.") % clampi(value, 1, RuneData.MAX_LEVEL)
		&"give_essence":
			QaTools.give_essence(profile, value)
			message = tr("The essence is now %d.") % profile.essence
		&"best_floor":
			QaTools.set_best_floor(profile, value)
			message = tr("The best floor is now %d.") % profile.best_depth
		&"clear_stages":
			QaTools.clear_every_stage(profile, tower)
			message = tr("Every stage is cleared.")
		&"start_run":
			var error := QaTools.start_run_at(profile, tower, value)
			message = error if not error.is_empty() else tr("A run waits at floor %d: Continue run on the hub.") % value
	if not _save():
		message = tr("Progress couldn't be saved.")
	show_qa(message)


func show_settings() -> void:
	var settings_screen := SETTINGS_SCENE.instantiate() as SettingsScreen
	_replace_screen(settings_screen)
	settings_screen.show_settings(settings)
	settings_screen.back_pressed.connect(show_title)
	settings_screen.credits_pressed.connect(show_credits)
	settings_screen.audio_live.connect(func() -> void: SettingsApplier.apply_audio(settings))
	settings_screen.changed.connect(_on_settings_changed)
	settings_screen.reset_save_confirmed.connect(_on_reset_save_confirmed)


## What stays on top of every screen: the mute button, in the top right corner.
func _build_overlay() -> void:
	var overlay := CanvasLayer.new()
	overlay.layer = 100
	add_child(overlay)
	_mute_button = MuteButton.new()
	_mute_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_mute_button.offset_left = -OVERLAY_MARGIN_X - 48.0
	_mute_button.offset_right = -OVERLAY_MARGIN_X
	_mute_button.offset_top = OVERLAY_MARGIN_Y
	_mute_button.offset_bottom = OVERLAY_MARGIN_Y + 44.0
	_mute_button.toggled.connect(_on_mute_toggled)
	overlay.add_child(_mute_button)
	_toast = PanelContainer.new()
	_toast.theme_type_variation = &"Chip"
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.offset_top = 12.0
	_toast_label = Label.new()
	_toast_label.theme_type_variation = &"PromptLabel"
	_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.add_child(_toast_label)
	_toast.hide()
	overlay.add_child(_toast)


func _on_mute_toggled(muted: bool) -> void:
	settings.muted = muted
	_on_settings_changed()
	if screen is SettingsScreen:
		(screen as SettingsScreen).sync_audio(settings)  # Its own checkbox follows.


## The achievements, a screen under the hub: back returns to it.
func show_achievements() -> void:
	var achievements_screen := ACHIEVEMENTS_SCENE.instantiate() as AchievementsScreen
	_replace_screen(achievements_screen)
	achievements_screen.show_achievements(profile)
	achievements_screen.back_pressed.connect(show_party)


## Records the achievements just met, saves, and shows a toast with their names.
func _unlock(unlocked: Array[AchievementData]) -> void:
	if unlocked.is_empty():
		return
	_save()
	var names: Array[String] = []
	for achievement in unlocked:
		names.append(tr(achievement.display_name))
	_show_toast(tr("Achievement unlocked: %s") % ", ".join(names))


## A message at the top of the screen for a few seconds, over every screen.
func _show_toast(text: String) -> void:
	_toast_label.text = text
	_toast.show()
	_toast.modulate.a = 1.0
	if _toast_tween != null:
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(TOAST_SECONDS)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.6)
	_toast_tween.tween_callback(_toast.hide)


## The credits, a screen under the settings: back returns to them.
func show_credits() -> void:
	var credits := CREDITS_SCENE.instantiate() as CreditsScreen
	_replace_screen(credits)
	credits.back_pressed.connect(show_settings)


## Records a dismissed hint so it doesn't come back.
func _dismiss_hint(id: String) -> void:
	hints.dismiss(id)
	_settings_store.save(settings)


func _on_settings_changed() -> void:
	SettingsApplier.apply(settings, get_window())
	_mute_button.show_muted(settings.muted)
	if not _settings_store.save(settings) and screen is SettingsScreen:
		(screen as SettingsScreen).show_message("Settings couldn't be saved.")


## A fresh profile; the settings stay.
func _on_reset_save_confirmed() -> void:
	profile = Profile.create(roster)
	_selected_hero = 0
	_summary = ""
	_applied_state = null
	_report = null
	var saved := _store.save(profile)
	if screen is SettingsScreen:
		(screen as SettingsScreen).show_message("Save reset." if saved else tr("Progress couldn't be saved."))


func show_party(message := "") -> void:
	var party := PARTY_SCENE.instantiate() as PartyScreen
	_replace_screen(party)
	party.selected_hero = _selected_hero
	party.hero_selected.connect(func(index: int) -> void: _selected_hero = index)
	party.back_pressed.connect(show_title)
	party.tower_pressed.connect(start_tower)
	party.stage_pressed.connect(start_stage)
	party.continue_pressed.connect(next_step)
	party.abandon_pressed.connect(_on_abandon_pressed)
	party.equip_requested.connect(_on_equip_requested)
	party.unequip_requested.connect(_on_unequip_requested)
	party.spells_pressed.connect(show_spells)
	party.salvage_requested.connect(_on_salvage_requested)
	party.fuse_requested.connect(_on_fuse_requested)
	party.achievements_pressed.connect(show_achievements)
	party.tutorial = tutorial
	party.tutorial_changed.connect(_on_settings_changed)
	party.show_profile(profile, _summary, message, tower)
	if hints.should_show("hub_intro") and not party.has_tutorial_step():  # It comes at the next visit.
		party.show_hint(hints.text("hub_intro"))
		party.hint_dismissed.connect(_dismiss_hint.bind("hub_intro"))


func start_tower(start_floor: int) -> void:
	if _tower_invalid():
		return
	_start_run(RunDirector.start_tower(profile, tower, start_floor))


func start_stage(stage_index: int) -> void:
	if _tower_invalid():
		return
	var stage := tower.stages[stage_index] if stage_index >= 0 and stage_index < tower.stages.size() else null
	_start_run(RunDirector.start_stage(profile, tower, stage))


## The run's next step: its pending boss choice, or its next battle (the hub when none).
func next_step() -> void:
	if profile.run == null:
		show_party()
	elif profile.run.awaiting_choice():
		var report := RunDirector.Report.new()
		report.won = true
		report.lines.append(tr("Pick a boon, or heal the party instead."))
		_show_run_screen(report, tr("Floor %d boss defeated") % profile.run.floor_number)
	else:
		start_battle()


func start_battle() -> void:
	if _tower_invalid():
		return
	var setup := RunDirector.battle_setup(profile, tower)
	var errors := setup.encounter.get_validation_errors() if setup.encounter != null else PackedStringArray(["no encounter"])
	if not errors.is_empty():
		show_party(tr("The floor's encounter is invalid: %s") % "; ".join(errors))
		return
	var spawns := setup.encounter.map.parse().player_spawns.size()
	if profile.party.is_empty() or profile.party.size() > spawns:
		show_party(tr("The party needs 1 to %d heroes to fight on this map.") % spawns)
		return
	var battle := BATTLE_SCENE.instantiate() as BattleController
	battle.setup(setup.encounter, setup.units, setup.modifiers, rng_seed, setup.hero_hp,
			setup.sudden_death_round, setup.sudden_death_percent, setup.title, setup.levels)
	battle.tutorial = tutorial
	battle.hints = hints
	battle.opening_tip = _opening_tip()
	battle.tutorial_changed.connect(_on_settings_changed)
	battle.sound.connect(audio.play_sfx)
	battle.settings = settings
	battle.speed_changed.connect(_on_settings_changed)
	battle.left_battle.connect(_on_battle_left)
	battle.battle_ended.connect(_apply_battle_result)
	battle.battle_finished.connect(_on_battle_finished)
	_battle_title = setup.title
	# A boss floor or a stage gets the driving track, the rest the calmer one.
	_battle_music = &"boss" if profile.run.mode == RunState.Mode.STAGE or TowerConfig.is_boss_floor(profile.run.floor_number) else &"battle"
	_replace_screen(battle)
	if battle.battle == null:
		show_party(tr("The battle couldn't start (see the log)."))


## The one-time tip a battle opens with: the first elite floor, boss floor or stage.
func _opening_tip() -> String:
	if profile.run.mode == RunState.Mode.STAGE:
		return "first_stage"
	if TowerConfig.is_boss_floor(profile.run.floor_number):
		return "first_boss"
	return "first_elite" if TowerConfig.is_elite_floor(profile.run.floor_number) else ""


## Shows the hub with the tower's errors, if any (a battle can't be generated from them).
func _tower_invalid() -> bool:
	var errors := tower.get_validation_errors() if tower != null else PackedStringArray(["no tower set"])
	if errors.is_empty():
		return false
	show_party(tr("The tower is invalid: %s") % "; ".join(errors))
	return true


func _start_run(error: String) -> void:
	if not error.is_empty():
		show_party(error)
		return
	_summary = ""
	_save()
	next_step()


## The battle's result screen was closed: the run screen shows what happened (the result
## is applied here if that was skipped).
func _on_battle_finished(state: BattleState) -> void:
	_apply_battle_result(state)
	var title := (tr("%s cleared") if _report.won else tr("%s lost")) % _battle_title
	_show_run_screen(_report, title)


## The player left a fight from its menu: nothing from it counts (no rewards, HP as before),
## and the run, saved between floors, waits at the same floor.
func _on_battle_left() -> void:
	_summary = tr("You left the fight. It starts over when you continue the run.")
	show_party()


## As soon as a battle ends, its result goes to the director (rewards, HP, next floor or
## run end) and the profile is saved.
func _apply_battle_result(state: BattleState) -> void:
	if state == _applied_state:
		return
	_applied_state = state
	var floor_number := profile.run.floor_number if profile.run != null else 0
	var is_stage := profile.run != null and profile.run.mode == RunState.Mode.STAGE
	_report = RunDirector.apply_result(profile, tower, state)
	_save()
	_unlock(Achievements.check(profile, Achievements.Context.from_battle(state, floor_number, is_stage) if _report.won else null))


func _show_run_screen(report: RunDirector.Report, title: String) -> void:
	var run_screen := RUN_SCENE.instantiate() as RunScreen
	_replace_screen(run_screen)
	run_screen.next_pressed.connect(next_step)
	run_screen.party_pressed.connect(show_party)
	run_screen.boss_choice_made.connect(_on_boss_choice_made)
	run_screen.back_pressed.connect(_on_back_pressed.bind(report))
	run_screen.show_report(report, profile, title)
	if not report.level_ups.is_empty() and hints.should_show("first_level_up"):
		run_screen.show_hint(hints.text("first_level_up"))
		run_screen.hint_dismissed.connect(_dismiss_hint.bind("first_level_up"))


func _on_boss_choice_made(choice: int, keep_going: bool) -> void:
	var report := RunDirector.apply_boss_choice(profile, choice, keep_going)
	_save()
	if report.run_over:
		_show_run_screen(report, tr("Run complete"))
	else:
		next_step()


## Back to the hub, with the run's last report as its summary.
func _on_back_pressed(report: RunDirector.Report) -> void:
	_summary = "\n".join(report.lines)
	show_party()


func _on_abandon_pressed() -> void:
	profile.run = null
	_summary = tr("Run abandoned.")
	_save()
	show_party()


## Runes change on the hub only, so never during a fight (a battle has no equipment UI, and a
## stray request while one is on screen is ignored). In a run, saved HP follows the new maxima.
func _on_equip_requested(hero_index: int, stash_index: int) -> void:
	if not screen is PartyScreen:
		return
	RunDirector.materialize_hp(profile)
	_finish_rune_change(profile.equip(hero_index, stash_index))


func _on_unequip_requested(hero_index: int, slot: int) -> void:
	if not screen is PartyScreen:
		return
	RunDirector.materialize_hp(profile)
	_finish_rune_change(profile.unequip(hero_index, slot))


## A hero's spells, to read and to change the loadout; back (or Esc) returns to the hub.
func show_spells(hero_index: int) -> void:
	if hero_index < 0 or hero_index >= profile.heroes.size():
		return
	var spells_screen := SPELLS_SCENE.instantiate() as SpellsScreen
	_replace_screen(spells_screen)
	spells_screen.show_spells(profile.heroes[hero_index])
	spells_screen.back_pressed.connect(show_party)
	spells_screen.assign_requested.connect(_on_loadout_requested.bind(hero_index))


## A spell changes slots, from the spells screen (reached from the hub: also between floors,
## never during a fight). Saved at once, like a rune change.
func _on_loadout_requested(slot: int, spell: SpellData, hero_index: int) -> void:
	if not screen is SpellsScreen:
		return
	var error := profile.assign_spell(hero_index, slot, spell)
	if error.is_empty() and not _save():
		error = tr("Progress couldn't be saved.")
	(screen as SpellsScreen).show_spells(profile.heroes[hero_index])
	if not error.is_empty():
		_show_toast(error)


## A rune is salvaged for essence, on the hub only (never during a fight). Maxima don't change
## (it wasn't equipped), so saved HP is untouched.
func _on_salvage_requested(stash_index: int) -> void:
	if not screen is PartyScreen:
		return
	var rune := profile.stash[stash_index] if stash_index >= 0 and stash_index < profile.stash.size() else null
	var value := rune.salvage_value() if rune != null else 0
	var error := profile.salvage_rune(stash_index)
	if error.is_empty() and not _save():
		error = tr("Progress couldn't be saved.")
	if error.is_empty():
		error = tr("Salvaged %s: +%d essence.") % [rune.title(), value]
	(screen as PartyScreen).show_profile(profile, _summary, error, tower)


## Three identical runes become one a level higher, for essence (hub only).
func _on_fuse_requested(stash_index: int) -> void:
	if not screen is PartyScreen:
		return
	var group := profile.fuse_group(stash_index)
	var error := profile.fuse(stash_index)
	if error.is_empty():
		error = tr("Fused into %s.") % profile.stash[group.min()].title()
		if not _save():
			error = tr("Progress couldn't be saved.")
	(screen as PartyScreen).show_profile(profile, _summary, error, tower)


func _finish_rune_change(error: String) -> void:
	if error.is_empty():
		RunDirector.clamp_hp(profile)
		_unlock(Achievements.check(profile))
		if not _save():
			error = tr("Progress couldn't be saved.")
	(screen as PartyScreen).show_profile(profile, _summary, error, tower)


## Saves the profile; a failure is added to the summary so the player knows.
func _save() -> bool:
	if _store.save(profile):
		return true
	if not _summary.contains(tr("Progress couldn't be saved.")):
		_summary = "\n".join([_summary, tr("Progress couldn't be saved.")].filter(func(t: String) -> bool: return not t.is_empty()))
	return false


## Swaps the current screen for `next`. The old one leaves the tree now and is freed at
## the end of the frame: it may be the one whose signal led here (a battle's Continue).
func _replace_screen(next: Node) -> void:
	if screen != null:
		remove_child(screen)
		screen.queue_free()
	screen = next
	add_child(next)
	if next is not StartScreen:  # Before the first click the browser plays nothing anyway.
		audio.play_music(_battle_music if next is BattleController else &"hub")
	if next is Screen:
		(next as Screen).focus_first.call_deferred()
