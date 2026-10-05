extends TestCase
## Audio plumbing: buses, volumes from the settings, sound events from the views, music per
## screen. (The sounds themselves are data; here the streams are generated.)

const GAME_SCENE := preload("res://scenes/game/game.tscn")
const SETTINGS_SCENE := preload("res://scenes/game/settings_screen.tscn")
const SAVE := "user://test_audio/profile.json"
const SETTINGS := "user://test_audio/settings.cfg"


func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func after_each_clean() -> void:
	SaveStore.new(SAVE).delete()
	SettingsStore.new(SETTINGS).delete()
	DirAccess.remove_absolute(SAVE.get_base_dir())
	SettingsApplier.apply_audio(Settings.new())


func _stream() -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_8_BITS
	wav.data = PackedByteArray([0, 10, 20, 10, 0])
	return wav


## A silent five-second stream (music has to still be playing when the test looks).
func _long_stream() -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_8_BITS
	var data := PackedByteArray()
	data.resize(44100 * 5)
	wav.data = data
	return wav


func _service(with_set := true) -> AudioService:
	var service := AudioService.new()
	if with_set:
		var set := AudioSet.new()
		for event in AudioSet.SFX_EVENTS:
			set.sfx[event] = _stream()
		for track in AudioSet.MUSIC_TRACKS:
			set.music[track] = _long_stream()
		set.sfx_gain_db[&"hit"] = -6.0
		service.audio_set = set
	_tree().root.add_child(service)
	return service


func test_the_music_and_effects_buses_exist_under_master_and_are_made_once() -> void:
	AudioService.ensure_buses()
	AudioService.ensure_buses()
	var music := AudioServer.get_bus_index(AudioService.MUSIC_BUS)
	var effects := AudioServer.get_bus_index(AudioService.EFFECTS_BUS)
	assert_true(music != -1 and effects != -1, "both buses")
	assert_eq([AudioServer.get_bus_send(music), AudioServer.get_bus_send(effects)], [&"Master", &"Master"])
	var named := 0
	for i in AudioServer.bus_count:
		if AudioServer.get_bus_name(i) == AudioService.MUSIC_BUS:
			named += 1
	assert_eq(named, 1, "not duplicated")


func test_volumes_map_the_sliders_onto_the_buses_and_mute_silences_master() -> void:
	var settings := Settings.new()
	settings.master_volume = 1.0
	settings.music_volume = 0.5
	settings.effects_volume = 0.0
	SettingsApplier.apply_audio(settings)
	var master := AudioServer.get_bus_index(AudioService.MASTER_BUS)
	assert_true(is_zero_approx(AudioServer.get_bus_volume_db(master)), "full slider: 0 dB")
	assert_true(absf(AudioServer.get_bus_volume_db(AudioServer.get_bus_index(AudioService.MUSIC_BUS)) - linear_to_db(0.5)) < 0.01, "half: about -6 dB")
	assert_eq(AudioServer.get_bus_volume_db(AudioServer.get_bus_index(AudioService.EFFECTS_BUS)), AudioService.SILENT_DB, "zero: silent")
	assert_false(AudioServer.is_bus_mute(master))
	settings.muted = true
	SettingsApplier.apply_audio(settings)
	assert_true(AudioServer.is_bus_mute(master), "muted")


func test_audio_settings_are_saved_clamped_and_bad_values_ignored() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE.get_base_dir())
	var store := SettingsStore.new(SETTINGS)
	var settings := Settings.new()
	settings.master_volume = 0.3
	settings.music_volume = 0.0
	settings.effects_volume = 1.0
	settings.muted = true
	assert_true(store.save(settings))
	var loaded := store.load_or_default()
	assert_eq([loaded.master_volume, loaded.music_volume, loaded.effects_volume, loaded.muted], [0.3, 0.0, 1.0, true])
	var file := FileAccess.open(SETTINGS, FileAccess.WRITE)
	file.store_string("[audio]\nmaster_volume=7.0\nmusic_volume=\"loud\"\nmuted=3\n")
	file.close()
	loaded = store.load_or_default()
	assert_eq([loaded.master_volume, loaded.music_volume, loaded.muted], [1.0, Settings.new().music_volume, false], "clamped, ignored, ignored")


func test_a_sound_event_plays_on_the_effects_bus_with_its_gain() -> void:
	var service := _service()
	service.play_sfx(&"hit")
	var playing := service.get_children().filter(func(c: Node) -> bool: return c is AudioStreamPlayer and (c as AudioStreamPlayer).bus == AudioService.EFFECTS_BUS and (c as AudioStreamPlayer).stream != null)
	assert_eq(playing.size(), 1, "one pooled player took it")
	assert_eq((playing[0] as AudioStreamPlayer).volume_db, -6.0, "the event's gain")
	for i in AudioService.POOL_SIZE + 2:
		service.play_sfx(&"ui_click")  # More sounds than players: the pool goes round, no error.
	assert_eq(service.requested.back(), &"ui_click")
	service.free()


func test_unknown_or_missing_sounds_do_nothing_and_a_service_without_a_set_is_silent() -> void:
	var service := _service()
	service.play_sfx(&"no_such_sound")
	var silent := _service(false)
	silent.play_sfx(&"hit")
	silent.play_music(&"hub")
	assert_eq(silent.requested, [&"hit"] as Array[StringName], "asked for, nothing to play")
	assert_eq(silent.current_music, &"hub")
	service.free()
	silent.free()


func test_music_changes_by_track_and_the_same_track_is_left_alone() -> void:
	var service := _service()
	service.play_music(&"hub")
	var first := service._music_active
	service.play_music(&"hub")
	assert_eq(service._music_active, first, "the same track doesn't restart")
	service.play_music(&"battle")
	assert_eq([service.current_music, service._music_active != first], [&"battle", true], "the other player takes over")
	service.stop_music()
	assert_eq(service.current_music, &"")
	service.free()


func test_every_button_that_appears_clicks_once_when_pressed() -> void:
	var service := _service()
	service.hook_buttons(_tree())
	var button := Button.new()
	_tree().root.add_child(button)
	button.pressed.emit()
	assert_eq(service.requested, [&"ui_click"] as Array[StringName])
	_tree().root.remove_child(button)
	_tree().root.add_child(button)  # Re-added: still one hook.
	button.pressed.emit()
	assert_eq(service.requested.size(), 2, "not hooked twice")
	_tree().node_added.disconnect(service._on_node_added)
	button.free()
	service.free()


func test_the_audio_set_is_validated() -> void:
	var set := AudioSet.new()
	assert_eq(set.get_validation_errors().size(), 0, "an empty set is fine")
	set.sfx[&"boom"] = _stream()
	set.music[&"hub"] = null
	assert_eq(set.get_validation_errors().size(), 2, "an unknown event and an empty stream")
	assert_eq((load("res://data/audio/audio_set.tres") as AudioSet).get_validation_errors().size(), 0, "the shipped set")


func test_the_event_player_announces_what_to_hear() -> void:
	Engine.time_scale = 10.0
	var hero := BattleFixtures.unit("P0", 200, 3, 6, 20)
	hero.spells = [BattleFixtures.damage_spell(2, 1, 5, 30)] as Array[SpellData]
	var enemy := BattleFixtures.unit("E0", 100, 3, 6, 20)
	var battle := Battle.new(BattleFixtures.state_with("0p 0 0 0e", [hero], [enemy]))
	battle.start()
	var root := Node3D.new()
	var board := BoardView.new()
	var units := UnitsView.new()
	var player := EventPlayer.new()
	for node: Node in [board, units, player]:
		root.add_child(node)
	_tree().root.add_child(root)
	board.build(battle.state.grid)
	units.build(battle.state, board)
	player.setup(units, board)
	var heard: Array[StringName] = []
	player.sound.connect(func(event: StringName) -> void: heard.append(event))
	var events: Array[BattleEvents.Event] = []
	events.append_array(battle.perform(BattleActions.Move.new(0, Vector2i(2, 0))).events)
	events.append_array(battle.perform(BattleActions.CastSpell.new(0, 0, Vector2i(3, 0))).events)
	await player.play(events)
	assert_true(heard.count(&"step") == 2, "a footstep per cell: %s" % [heard])
	assert_true(heard.find(&"cast") > heard.find(&"step"), "the cast after the walk")
	assert_true(heard.find(&"hit") > heard.find(&"cast"), "the hit after the cast")
	assert_true(&"death" in heard, "the enemy dies of 30 damage: %s" % [heard])
	root.free()
	Engine.time_scale = 1.0


func _game() -> Game:
	DirAccess.make_dir_recursive_absolute(SAVE.get_base_dir())
	var game := GAME_SCENE.instantiate() as Game
	game.play_opens_multiplayer = false  # These tests use the single-player hub.
	game.require_click_to_start = false  # Straight to the title.
	game.save_path = SAVE
	game.settings_path = SETTINGS
	game.rng_seed = 5
	_tree().root.add_child(game)
	return game


func test_the_game_plays_the_hub_music_on_menus_and_the_battle_music_in_a_fight() -> void:
	var game := _game()
	assert_eq(game.audio.current_music, &"hub", "the title")
	(game.screen.find_child("PlayButton", true, false) as Button).pressed.emit()
	assert_eq(game.audio.current_music, &"hub", "the hub")
	game.start_tower(1)
	assert_eq(game.audio.current_music, &"battle", "a fight")
	game.show_party()
	assert_eq(game.audio.current_music, &"hub", "back at the hub")
	game.free()


func test_the_controller_announces_the_players_turn_and_the_result() -> void:
	Engine.time_scale = 10.0
	var hero := BattleFixtures.unit("P0", 200, 3, 6, 20)
	var enemy := BattleFixtures.unit("E0", 100, 3, 6, 20)
	var controller := (load("res://scenes/battle/battle.tscn") as PackedScene).instantiate() as BattleController
	controller.rng_seed = 7
	controller.encounter = BattleFixtures.encounter("0p 0 0 0e", [enemy])
	controller.players = [hero] as Array[UnitData]
	_tree().root.add_child(controller)
	var heard: Array[StringName] = []
	controller.sound.connect(func(event: StringName) -> void: heard.append(event))
	controller.end_turn()  # Ready.
	for i in 900:
		if controller.input_state == BattleController.State.IDLE:
			break
		await _tree().process_frame
	assert_true(heard.has(&"turn_start"), "the player's turn: %s" % [heard])
	for unit in controller.battle.state.units:
		if unit.team == UnitState.Team.ENEMY:
			unit.hp = 0
	controller._begin_next()  # What follows a playback: the battle is over.
	for i in 900:
		if controller.input_state == BattleController.State.ENDED:
			break
		await _tree().process_frame
	assert_true(heard.has(&"victory"), "the stinger: %s" % [heard])
	controller.free()
	Engine.time_scale = 1.0


func test_the_settings_screen_sliders_and_mute_edit_the_settings() -> void:
	var settings := Settings.new()
	var screen := SETTINGS_SCENE.instantiate() as SettingsScreen
	_tree().root.add_child(screen)
	screen.show_settings(settings)
	var changes := [0]
	screen.changed.connect(func() -> void: changes[0] += 1)
	assert_eq((screen.get_node("%MasterVolume") as HSlider).value, settings.master_volume, "shows the current value")
	(screen.get_node("%MusicVolume") as HSlider).value = 0.25
	(screen.get_node("%EffectsVolume") as HSlider).value = 0.1
	(screen.get_node("%MasterVolume") as HSlider).value = 0.9
	(screen.get_node("%Muted") as CheckButton).button_pressed = true
	assert_eq([settings.music_volume, settings.effects_volume, settings.master_volume, settings.muted], [0.25, 0.1, 0.9, true])
	assert_eq(changes[0], 4, "each edit reports itself")
	screen.free()


func test_a_cooldown_stops_a_sound_from_stacking_and_pitch_varies_within_bounds() -> void:
	var service := _service()
	service.audio_set.sfx_cooldown[&"step"] = 5.0
	service.audio_set.sfx_pitch_variation[&"hit"] = 0.1
	service.play_sfx(&"step")
	service.play_sfx(&"step")
	var started := service.get_children().filter(func(c: Node) -> bool: return c is AudioStreamPlayer and (c as AudioStreamPlayer).stream != null and (c as AudioStreamPlayer).bus == AudioService.EFFECTS_BUS)
	assert_eq(started.size(), 1, "the second step inside the cooldown was dropped")
	for i in 20:
		service.play_sfx(&"hit")
	for child in service.get_children():
		if child is AudioStreamPlayer and (child as AudioStreamPlayer).bus == AudioService.EFFECTS_BUS:
			assert_true(absf((child as AudioStreamPlayer).pitch_scale - 1.0) <= 0.1001, "pitch within 10 %%: %f" % (child as AudioStreamPlayer).pitch_scale)
	service.free()


func test_music_streams_are_set_to_loop() -> void:
	var mp3 := AudioStreamMP3.new()
	var ogg := AudioStreamOggVorbis.new()
	var wav := _stream()
	for stream: AudioStream in [mp3, ogg, wav]:
		AudioService.make_loop(stream)
	assert_eq([mp3.loop, ogg.loop, wav.loop_mode], [true, true, AudioStreamWAV.LOOP_FORWARD])


func test_boss_floors_and_stages_get_the_boss_music_and_other_floors_the_battle_one() -> void:
	var game := _game()
	game.start_tower(1)
	assert_eq(game.audio.current_music, &"battle", "floor 1")
	game.profile.run.floor_number = 10
	game.start_battle()
	assert_eq(game.audio.current_music, &"boss", "a boss floor")
	game.profile.run.floor_number = 5
	game.start_battle()
	assert_eq(game.audio.current_music, &"battle", "an elite floor is still an ordinary battle")
	game.free()


func test_the_shipped_sounds_are_in_the_set_and_credited() -> void:
	var set := load("res://data/audio/audio_set.tres") as AudioSet
	for event: StringName in [&"ui_click", &"hit", &"heal", &"step", &"defeat", &"cast", &"cast_fire", &"cast_fireball", &"cast_physical", &"cast_poison", &"death", &"victory"]:
		assert_true(set.sfx.get(event) != null, "a sound for %s" % event)
	for track: StringName in [&"hub", &"battle", &"boss"]:
		assert_true(set.music.get(track) != null, "a track for %s" % track)
	var source := FileAccess.get_file_as_string("res://assets/audio/SOURCE.md")
	var credits := FileAccess.get_file_as_string("res://CREDITS.md")
	for dir in ["sfx", "music"]:
		for file in DirAccess.get_files_at("res://assets/audio/%s" % dir):
			if file.get_extension() in ["ogg", "mp3", "wav"]:
				assert_true(source.contains("%s/%s" % [dir, file]), "%s/%s is listed in SOURCE.md" % [dir, file])
	assert_true(credits.contains("assets/audio/sfx") and credits.contains("assets/audio/music/hub.mp3"), "credited in CREDITS.md")


func test_the_mute_button_is_on_every_screen_and_stays_in_step_with_the_settings() -> void:
	var game := _game()
	var button := game.find_child("MuteButton", true, false) as MuteButton
	assert_true(button != null and button.is_visible_in_tree(), "on the title")
	button.button_pressed = true
	assert_true(game.settings.muted, "clicking mutes")
	assert_true(AudioServer.is_bus_mute(AudioServer.get_bus_index(AudioService.MASTER_BUS)), "master is muted")
	assert_eq(button.icon, MuteButton.SOUND_OFF, "the crossed speaker")
	assert_true(SettingsStore.new(SETTINGS).load_or_default().muted, "and it is saved")
	(game.screen.find_child("PlayButton", true, false) as Button).pressed.emit()
	assert_true(button.is_visible_in_tree() and button.button_pressed, "still there on the hub, still muted")
	game.start_tower(1)
	assert_true(button.is_visible_in_tree(), "and in a fight")
	game.show_settings()
	var check := game.screen.get_node("%Muted") as CheckButton
	assert_true(check.button_pressed, "the settings checkbox shows the mute")
	button.button_pressed = false
	assert_false(check.button_pressed, "the corner button moves the checkbox")
	check.button_pressed = true
	assert_true(button.button_pressed and game.settings.muted, "and the checkbox moves the corner button")
	assert_eq(button.focus_mode, Control.FOCUS_NONE, "it never takes the keyboard focus")
	game.free()


func test_a_track_change_is_a_cross_fade_both_tracks_move_at_once() -> void:
	var service := _service()
	service.play_music(&"hub")
	await _tree().create_timer(1.0).timeout  # The first track fades in.
	var hub := service._music_players[service._music_active]
	assert_true(hub.volume_db > service.audio_set.music_gain_db - 2.0, "the hub track is up at its level: %f" % hub.volume_db)
	service.play_music(&"battle")
	var battle := service._music_players[service._music_active]
	await _tree().create_timer(0.3).timeout
	assert_true(battle.volume_db > AudioService.SILENT_DB + 5.0, "the new track is already rising: %f" % battle.volume_db)
	assert_true(hub.volume_db < service.audio_set.music_gain_db - 1.0 and hub.volume_db > AudioService.SILENT_DB + 1.0, "while the old one is still fading out, not gone: %f" % hub.volume_db)
	service.free()


func test_stopping_the_music_during_a_fade_leaves_no_player_playing() -> void:
	var service := _service()
	service.play_music(&"hub")
	await _tree().create_timer(0.6).timeout  # The hub track is well up.
	service.play_music(&"battle")
	await _tree().create_timer(0.2).timeout  # The hub track is half way out...
	service.stop_music()  # ...when everything is asked to stop.
	await _tree().create_timer(1.2).timeout
	for player: AudioStreamPlayer in service._music_players:
		assert_false(player.playing, "no music left playing")
		assert_true(player.volume_db <= AudioService.SILENT_DB + 0.5, "and none left audible: %f" % player.volume_db)
	service.free()


func test_dragging_a_volume_slider_applies_it_live_and_saves_once_when_released() -> void:
	var settings := Settings.new()
	var screen := SETTINGS_SCENE.instantiate() as SettingsScreen
	_tree().root.add_child(screen)
	screen.show_settings(settings)
	var live := [0]
	var saves := [0]
	screen.audio_live.connect(func() -> void: live[0] += 1)
	screen.changed.connect(func() -> void: saves[0] += 1)
	var slider := screen.get_node("%MusicVolume") as HSlider
	slider.drag_started.emit()
	slider.value = 0.2
	slider.value = 0.3
	slider.value = 0.35
	assert_eq([live[0], saves[0], settings.music_volume], [3, 0, 0.35], "heard at once, nothing saved mid-drag")
	slider.drag_ended.emit(true)
	assert_eq(saves[0], 1, "saved once when the knob is let go")
	slider.value = 0.4  # A key press: no drag, so it saves.
	assert_eq(saves[0], 2)
	screen.free()


func test_a_volume_that_is_not_a_number_is_ignored() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE.get_base_dir())
	var file := FileAccess.open(SETTINGS, FileAccess.WRITE)
	file.store_string("[audio]\nmaster_volume=nan\nmusic_volume=inf\n")
	file.close()
	var loaded := SettingsStore.new(SETTINGS).load_or_default()
	assert_eq([loaded.master_volume, loaded.music_volume], [Settings.new().master_volume, Settings.new().music_volume])


func test_a_spells_cast_sound_is_its_own_then_its_damage_types_then_the_generic_one() -> void:
	var spell := BattleFixtures.damage_spell()
	assert_eq(spell.cast_sound_event(), &"cast", "an untyped spell: the generic cast")
	var fire := DamageType.new()
	fire.display_name = "Fire"
	fire.cast_sound = &"cast_fire"
	(spell.effects[0] as DamageEffect).damage_type = fire
	assert_eq(spell.cast_sound_event(), &"cast_fire", "the damage type's")
	spell.cast_sound = &"cast_poison"
	assert_eq(spell.cast_sound_event(), &"cast_poison", "the spell's own wins")
	var heal := BattleFixtures.damage_spell()
	heal.effects = [HealEffect.new()] as Array[EffectData]
	assert_eq(heal.cast_sound_event(), &"cast", "a heal has no damage type")


func test_unknown_cast_sound_names_are_validation_errors() -> void:
	var spell := BattleFixtures.damage_spell()
	spell.cast_sound = &"boom"
	assert_true(Array(spell.get_validation_errors()).any(func(e: String) -> bool: return "unknown cast_sound" in e))
	var type := DamageType.new()
	type.display_name = "X"
	type.cast_sound = &"boom"
	assert_true(Array(type.get_validation_errors()).any(func(e: String) -> bool: return "unknown cast_sound" in e))
	type.cast_sound = &"cast_fire"
	assert_eq(type.get_validation_errors().size(), 0)


func test_the_event_player_announces_the_spells_own_cast_sound() -> void:
	Engine.time_scale = 10.0
	var spell := BattleFixtures.damage_spell(2, 1, 5, 3)
	spell.cast_sound = &"cast_fire"
	var hero := BattleFixtures.unit("P0", 200, 3, 6, 20)
	hero.spells = [spell] as Array[SpellData]
	var battle := Battle.new(BattleFixtures.state_with("0p 0 0 0e", [hero], [BattleFixtures.unit("E0", 100, 3, 6, 40)]))
	battle.start()
	var root := Node3D.new()
	var board := BoardView.new()
	var units := UnitsView.new()
	var player := EventPlayer.new()
	for node: Node in [board, units, player]:
		root.add_child(node)
	_tree().root.add_child(root)
	board.build(battle.state.grid)
	units.build(battle.state, board)
	player.setup(units, board)
	var heard: Array[StringName] = []
	player.sound.connect(func(event: StringName) -> void: heard.append(event))
	await player.play(battle.perform(BattleActions.CastSpell.new(0, 0, Vector2i(3, 0))).events)
	assert_true(heard.has(&"cast_fire") and not heard.has(&"cast"), "the specific cast sound only: %s" % [heard])
	root.free()
	Engine.time_scale = 1.0


func test_a_victory_or_defeat_stinger_takes_the_music_out_and_the_next_screens_music_returns() -> void:
	for stinger: StringName in [&"victory", &"defeat"]:
		var service := _service()
		service.play_music(&"battle")
		await _tree().create_timer(0.3).timeout
		service.play_sfx(stinger)
		assert_eq(service.current_music, &"", "%s: the battle music is told to stop" % stinger)
		await _tree().create_timer(1.1).timeout
		for player: AudioStreamPlayer in service._music_players:
			assert_false(player.playing, "%s: no music under the fanfare" % stinger)
		service.play_music(&"hub")
		assert_eq(service.current_music, &"hub", "the next screen's music starts again")
		assert_true(service._music_players[service._music_active].playing)
		service.free()
	var plain := _service()
	plain.play_music(&"battle")
	plain.play_sfx(&"hit")
	assert_eq(plain.current_music, &"battle", "an ordinary sound leaves the music alone")
	plain.free()


func test_the_next_screens_music_cuts_off_a_fanfare_still_playing() -> void:
	var service := _service()
	service.audio_set.sfx[&"victory"] = _long_stream()  # A fanfare that outlasts the click on Continue.
	service.play_music(&"boss")
	service.play_sfx(&"victory")
	var fanfare := service._stinger
	assert_true(fanfare != null and fanfare.playing, "the fanfare plays")
	service.play_music(&"hub")  # Continue: the run screen's music.
	await _tree().create_timer(0.7).timeout
	assert_false(fanfare.playing, "the fanfare was cut off when the next music started")
	assert_true(service._music_players[service._music_active].volume_db > -15.0, "and the new music fades in: %f" % service._music_players[service._music_active].volume_db)
	var other := _service()
	other.audio_set.sfx[&"hit"] = _long_stream()
	other.play_sfx(&"hit")
	other.play_music(&"hub")
	assert_true(other._stinger == null, "an ordinary sound is no stinger and is never cut")
	service.free()
	other.free()


func test_the_music_plays_below_full_scale_so_spell_sounds_stand_out_and_heal_stays_gentle() -> void:
	var set := load("res://data/audio/audio_set.tres") as AudioSet
	assert_true(set.music_gain_db < 0.0, "music at %f dB" % set.music_gain_db)
	for event: StringName in [&"cast", &"cast_fire", &"cast_fireball", &"cast_physical", &"cast_poison"]:
		assert_true(set.sfx_gain_db.get(event, 0.0) > set.music_gain_db - 6.0, "%s isn't buried under the music" % event)
	assert_true(set.sfx_gain_db.get(&"heal", 0.0) <= -6.0, "the heal sound is kept gentle (the first one was found disturbing)")
	var service := _service()
	service.audio_set.music_gain_db = -12.0
	service.play_music(&"hub")
	await _tree().create_timer(1.0).timeout
	var level: float = service._music_players[service._music_active].volume_db
	assert_true(absf(level + 12.0) < 1.0, "the track settles at the set's music gain: %f" % level)
	service.free()
