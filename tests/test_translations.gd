extends TestCase
## The French file covers every text the game can show, keeps each placeholder, and nothing
## shown on a Control is formatted without going through tr().

const GAME_SCENE := preload("res://scenes/game/game.tscn")
const SAVE := "user://test_translations/profile.json"
const SETTINGS := "user://test_translations/settings.cfg"

var _specifiers := RegEx.create_from_string("%%|%[+\\- 0-9.]*[sdf]|\\{[a-z_]+\\}")


func after_each_clean() -> void:
	SaveStore.new(SAVE).delete()
	SettingsStore.new(SETTINGS).delete()
	DirAccess.remove_absolute(SAVE.get_base_dir())


func _scan() -> StringScanner:
	var scanner := StringScanner.new()
	scanner.scan_all()
	return scanner


func _placeholders(text: String) -> Array[String]:
	var found: Array[String] = []
	for match in _specifiers.search_all(text):
		found.append(match.get_string())
	return found  # In order: GDScript's % has no positional arguments, so a swap would crash or misprint.


func test_every_text_found_in_the_game_has_a_french_translation() -> void:
	var scanner := _scan()
	var french := PoFile.load_file("res://locale/fr.po")
	var missing: Array[String] = []
	for key in scanner.entries:
		var entry: PoFile.PoEntry = french.entries.get(key)
		if entry == null or not entry.is_translated():
			missing.append(scanner.entries[key].id)
	assert_eq(missing, [] as Array[String], "untranslated (run tools/extract_strings.gd, then translate)")
	assert_true(scanner.entries.size() > 100, "the scan finds the game's texts: %d" % scanner.entries.size())


func test_the_french_file_holds_no_text_the_game_no_longer_uses() -> void:
	var scanner := _scan()
	var french := PoFile.load_file("res://locale/fr.po")
	var stale: Array[String] = []
	for key in french.entries:
		if not scanner.entries.has(key):
			stale.append(french.entries[key].id)
	assert_eq(stale, [] as Array[String], "obsolete entries (run tools/extract_strings.gd)")


func test_translations_keep_the_placeholders_of_their_english_text() -> void:
	var french := PoFile.load_file("res://locale/fr.po")
	for key in french.entries:
		var entry := french.entries[key]
		var expected := _placeholders(entry.id)
		for index in entry.translations.size():
			var source := entry.id if index == 0 or entry.plural.is_empty() else entry.plural
			assert_eq(_placeholders(entry.translations[index]), _placeholders(source), "placeholders of \"%s\" (%d)" % [entry.id, index])
		assert_true(not expected.is_empty() or not entry.translations[0].contains("%"), "no stray %% in \"%s\"" % entry.id)


func test_no_formatted_text_is_set_on_a_control_without_tr() -> void:
	assert_eq(_scan().unrouted, [] as Array[String], "wrap these in tr()")


func test_the_po_file_reads_back_as_written() -> void:
	var french := PoFile.load_file("res://locale/fr.po")
	var again := PoFile.new()
	again._parse(french.to_text())
	assert_eq(again.entries.size(), french.entries.size())
	assert_eq(again.to_text(), french.to_text(), "stable under a read and write")
	var turns := french.entries[PoFile.key_of("", "%d turn")]
	assert_eq(turns.translations, ["%d tour", "%d tours"] as Array[String], "plural forms")


func test_the_title_screen_is_in_french_when_french_is_chosen() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE.get_base_dir())
	var settings := Settings.new()
	settings.language = "fr"
	var store := SettingsStore.new(SETTINGS)
	assert_true(store.save(settings))
	var game := GAME_SCENE.instantiate() as Game
	game.play_opens_multiplayer = false  # These tests use the single-player hub.
	game.require_click_to_start = false  # Straight to the title.
	game.save_path = SAVE
	game.settings_path = SETTINGS
	(Engine.get_main_loop() as SceneTree).root.add_child(game)
	assert_eq(TranslationServer.get_locale(), "fr")
	var play := game.screen.find_child("PlayButton", true, false) as Button
	assert_eq([play.text, play.atr(play.text)], ["Play", "Jouer"], "the source text stays English; what shows is French")
