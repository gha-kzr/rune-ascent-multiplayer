extends TestCase
## The settings screen edits Settings in place and reports it; rebinding captures one key.

const SCENE := preload("res://scenes/game/settings_screen.tscn")
const CREDITS := "user://test_settings_screen/credits.md"


func after_each_clean() -> void:
	SettingsApplier.reset_bindings(Settings.new())
	DirAccess.remove_absolute(CREDITS)
	DirAccess.remove_absolute(CREDITS.get_base_dir())


func _screen(settings: Settings) -> SettingsScreen:
	var screen := SCENE.instantiate() as SettingsScreen
	(Engine.get_main_loop() as SceneTree).root.add_child(screen)
	screen.show_settings(settings)
	return screen


func _key(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code  # ui_cancel matches on the logical key.
	event.pressed = true
	return event


func _button(screen: Node, node_name: String) -> Button:
	return screen.find_child(node_name, true, false) as Button


func test_shows_the_current_settings() -> void:
	var settings := Settings.new()
	settings.ui_scale = 1.25
	settings.window_mode = Settings.WindowMode.FULLSCREEN
	var screen := _screen(settings)
	assert_eq((screen.get_node("%UiScale") as OptionButton).selected, 2)
	assert_eq((screen.get_node("%WindowMode") as OptionButton).get_selected_id(), int(Settings.WindowMode.FULLSCREEN))
	assert_eq(screen.get_node("%Bindings").get_child_count(), Settings.REBINDABLE.size() * 2, "a label and a key per action")
	assert_eq(_button(screen, "Key_spell_1").text, SettingsApplier.key_text(&"spell_1"))
	screen.free()


func test_changing_display_options_edits_the_settings_and_reports_it() -> void:
	var settings := Settings.new()
	var screen := _screen(settings)
	var reports := {"count": 0}
	screen.changed.connect(func() -> void: reports.count += 1)
	(screen.get_node("%UiScale") as OptionButton).item_selected.emit(3)
	(screen.get_node("%WindowMode") as OptionButton).item_selected.emit(1)
	assert_eq([settings.ui_scale, settings.window_mode, reports.count], [1.5, Settings.WindowMode.FULLSCREEN, 2])
	screen.free()


func test_rebinding_captures_the_next_key() -> void:
	var settings := Settings.new()
	var screen := _screen(settings)
	var reports := {"count": 0}
	screen.changed.connect(func() -> void: reports.count += 1)
	_button(screen, "Key_spell_1").pressed.emit()
	assert_true(screen.is_capturing())
	assert_eq(_button(screen, "Key_spell_1").text, "Press a key...")
	screen._input(_key(KEY_SHIFT))
	assert_true(screen.is_capturing(), "a modifier alone keeps waiting")
	screen._input(_key(KEY_Z))
	assert_false(screen.is_capturing())
	assert_eq([settings.bindings[&"spell_1"], SettingsApplier.key_of(&"spell_1"), reports.count], [int(KEY_Z), int(KEY_Z), 1])
	screen.free()


func test_a_taken_key_is_refused_with_a_message() -> void:
	var settings := Settings.new()
	var screen := _screen(settings)
	screen.begin_capture(&"spell_1")
	screen._input(_key(KEY_2))
	assert_true((screen.get_node("%Message") as Label).text.contains("Spell 2"))
	assert_eq(settings.bindings.size(), 0)
	screen.free()


func test_esc_cancels_a_capture_instead_of_going_back() -> void:
	var settings := Settings.new()
	var screen := _screen(settings)
	var backs := {"count": 0}
	screen.back_pressed.connect(func() -> void: backs.count += 1)
	screen.begin_capture(&"spell_1")
	screen.get_viewport().push_input(_key(KEY_ESCAPE))
	assert_false(screen.is_capturing())
	assert_eq([backs.count, settings.bindings.size()], [0, 0], "cancelled, not bound, not back")
	screen.get_viewport().push_input(_key(KEY_ESCAPE))
	assert_eq(backs.count, 1, "the next Esc goes back")
	screen.free()


func test_reset_keys_restores_the_defaults() -> void:
	var settings := Settings.new()
	var screen := _screen(settings)
	SettingsApplier.set_binding(settings, &"spell_1", KEY_Z)
	_button(screen, "ResetKeysButton").pressed.emit()
	assert_eq([SettingsApplier.key_of(&"spell_1"), settings.bindings.size()], [int(KEY_1), 0])
	screen.free()


func test_reset_save_needs_a_confirmation() -> void:
	var screen := _screen(Settings.new())
	var resets := {"count": 0}
	screen.reset_save_confirmed.connect(func() -> void: resets.count += 1)
	var confirm := screen.get_node("%ConfirmRow") as Control
	assert_false(confirm.visible)
	_button(screen, "ResetSaveButton").pressed.emit()
	assert_true(confirm.visible)
	assert_eq(resets.count, 0, "asking isn't resetting")
	_button(screen, "ConfirmNoButton").pressed.emit()
	assert_false(confirm.visible)
	assert_eq(resets.count, 0)
	_button(screen, "ResetSaveButton").pressed.emit()
	_button(screen, "ConfirmYesButton").pressed.emit()
	assert_eq(resets.count, 1)
	assert_false(confirm.visible)
	screen.free()


func test_show_hints_again_forgets_the_dismissed_ones() -> void:
	var settings := Settings.new()
	settings.dismissed_hints = ["hub_intro"] as Array[String]
	var screen := _screen(settings)
	var reports := {"count": 0}
	screen.changed.connect(func() -> void: reports.count += 1)
	_button(screen, "ShowHintsButton").pressed.emit()
	assert_eq([settings.dismissed_hints.size(), reports.count], [0, 1])
	screen.free()


func test_credits_show_tables_and_headings_but_not_contributor_prose() -> void:
	DirAccess.make_dir_recursive_absolute(CREDITS.get_base_dir())
	var file := FileAccess.open(CREDITS, FileAccess.WRITE)
	file.store_string("# Credits\n\nAdd a row whenever a file is added.\n\n| Asset | Files | Source | Author | License |\n|---|---|---|---|---|\n| Icons | `ui/icons/*.svg` | [site](https://x.y) | Lorc | [CC BY 3.0](https://z) |\n\n## By author\n\n| Author | Icons |\n|---|---|\n| Lorc | `arrow` |\n\n- Thanks to [a friend](https://x)\n")
	file.close()
	var lines := CreditsScreen.credits_text(CREDITS).split("\n")
	assert_eq(lines, PackedStringArray(["Credits", "Asset — Source — Author — License", "Icons — site — Lorc — CC BY 3.0", "", "By author", "Author — Icons", "Lorc — arrow", "Thanks to a friend"]))
	assert_eq(CreditsScreen.credits_text("user://nope.md"), CreditsScreen.CREDITS_FALLBACK)


func test_the_real_credits_list_the_assets_without_the_rules() -> void:
	var text := CreditsScreen.credits_text()
	assert_true(text.contains("Kenney") and text.contains("Lorc") and text.contains("CC0 1.0") and text.contains("game-icons.net"), text)
	assert_false(text.contains("Add a row"), "contributor rules stay out of the game")
	assert_false(text.contains("http"), "no raw links")
	assert_false(text.contains("`"), "no markdown marks")


func test_a_key_reported_only_by_its_logical_code_still_binds() -> void:
	var settings := Settings.new()
	var screen := _screen(settings)
	screen.begin_capture(&"spell_1")
	var event := InputEventKey.new()
	event.keycode = KEY_Z
	event.pressed = true  # physical_keycode stays 0, as on some web / IME setups.
	screen._input(event)
	assert_eq(settings.bindings.get(&"spell_1"), int(KEY_Z))
	screen.begin_capture(&"spell_2")
	var empty := InputEventKey.new()
	empty.pressed = true
	screen._input(empty)
	assert_true(screen.is_capturing(), "no usable key: keep waiting")
	screen.free()


func test_a_reserved_key_shows_a_message_and_binds_nothing() -> void:
	var settings := Settings.new()
	var screen := _screen(settings)
	screen.begin_capture(&"spell_1")
	screen._input(_key(KEY_ENTER))
	assert_true((screen.get_node("%Message") as Label).text.contains("reserved"))
	assert_eq(settings.bindings.size(), 0)
	screen.free()


func test_focus_returns_to_reset_save_when_the_confirm_row_goes_away() -> void:
	var screen := _screen(Settings.new())
	_button(screen, "ResetSaveButton").pressed.emit()
	assert_eq(screen.get_viewport().gui_get_focus_owner().name, &"ConfirmNoButton")
	_button(screen, "ConfirmNoButton").pressed.emit()
	assert_eq(screen.get_viewport().gui_get_focus_owner().name, &"ResetSaveButton", "the keyboard isn't left with nothing")
	screen.free()


func test_the_language_row_shows_and_changes_the_language() -> void:
	var settings := Settings.new()
	settings.language = "fr"
	var screen := _screen(settings)
	var language := screen.get_node("%Language") as OptionButton
	assert_eq(language.item_count, Localization.LANGUAGES.size() + 1, "automatic, then each language")
	assert_eq(language.get_item_text(language.selected), "Français", "the current language, in its own name")
	var changes := [0]
	screen.changed.connect(func() -> void: changes[0] += 1)
	language.select(0)
	language.item_selected.emit(0)
	assert_eq([settings.language, changes[0]], ["", 1], "automatic is the empty code")
	language.select(1)
	language.item_selected.emit(1)
	assert_eq(settings.language, "en")


func test_the_credits_have_a_screen_of_their_own_reached_from_the_settings_and_left_by_the_back_arrow() -> void:
	var game := (load("res://scenes/game/game.tscn") as PackedScene).instantiate() as Game
	game.play_opens_multiplayer = false  # These tests use the single-player hub.
	game.save_path = "user://test_settings_screen/profile.json"
	game.settings_path = "user://test_settings_screen/settings.cfg"
	DirAccess.make_dir_recursive_absolute("user://test_settings_screen")
	(Engine.get_main_loop() as SceneTree).root.add_child(game)
	game.show_settings()
	var back := game.screen.find_child("BackButton", true, false) as Button
	assert_true(back.icon != null and back.text.is_empty(), "the settings go back with an arrow, not a word")
	(game.screen.find_child("CreditsButton", true, false) as Button).pressed.emit()
	assert_true(game.screen is CreditsScreen, "the credits screen")
	var text := (game.screen.find_child("Credits", true, false) as Label).text
	assert_true(text.contains("Lorc") and text.contains("Kenney"), "lists the assets")
	var credits_back := game.screen.find_child("BackButton", true, false) as Button
	assert_true(credits_back.icon != null and credits_back.text.is_empty(), "with a back arrow too")
	credits_back.pressed.emit()
	assert_true(game.screen is SettingsScreen, "back to the settings")
	game.free()
	DirAccess.remove_absolute("user://test_settings_screen/profile.json")
	DirAccess.remove_absolute("user://test_settings_screen/settings.cfg")
	DirAccess.remove_absolute("user://test_settings_screen")
