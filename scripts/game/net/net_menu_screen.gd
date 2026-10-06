class_name NetMenuScreen
extends Screen
## The multiplayer front page: a name, "Host a match", or paste an invite (code or link) to join one.
## An invite link opened in the browser fills the code in and joins by itself.

signal host_requested(player_name: String)
signal join_requested(player_name: String, code: String)

const NAME_FILE := "user://net_player.cfg"

var _name_edit: LineEdit
var _code_edit: LineEdit
var _status: Label
var _join_button: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color(0.1, 0.11, 0.14)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(560, 0)
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)
	var title := Label.new()
	title.theme_type_variation = &"HeaderLabel"
	title.text = "Multiplayer"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var intro := Label.new()
	intro.theme_type_variation = &"SmallLabel"
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.text = "Fight other players, one hero each. Nothing to install and no server: the players connect to each other directly."
	box.add_child(intro)
	_name_edit = _line("Your name", box)
	_name_edit.name = "NameEdit"
	_name_edit.max_length = MatchState.MAX_NAME
	_name_edit.text = _saved_name()
	var host := HubStyle.button("Host a match", "HostButton")
	host.custom_minimum_size = Vector2(0, 48)
	host.pressed.connect(_on_host)
	box.add_child(host)
	var join_title := Label.new()
	join_title.theme_type_variation = &"PromptLabel"
	join_title.text = "Join a match"
	box.add_child(join_title)
	var how := Label.new()
	how.theme_type_variation = &"SmallLabel"
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	how.text = "Type the room code the host gave you (or paste their room link). With an invite link instead, you will get a reply to send back to them."
	box.add_child(how)
	_code_edit = LineEdit.new()
	_code_edit.name = "CodeEdit"
	_code_edit.placeholder_text = "Room code, or invite link"
	_code_edit.custom_minimum_size = Vector2(0, 44)
	_code_edit.text_submitted.connect(func(_text: String) -> void: _on_join())
	box.add_child(_code_edit)
	_join_button = HubStyle.button("Join", "JoinButton")
	_join_button.custom_minimum_size = Vector2(0, 48)
	_join_button.pressed.connect(_on_join)
	box.add_child(_join_button)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.theme_type_variation = &"SmallLabel"
	_status.add_theme_color_override("font_color", Color(1.0, 0.6, 0.5))
	box.add_child(_status)
	if not WebPage.is_web():
		var note := Label.new()
		note.theme_type_variation = &"SmallLabel"
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.text = "Multiplayer needs the web version of the game (it uses the browser's WebRTC)."
		box.add_child(note)
	var back := HubStyle.button("Back", "BackButton")
	back.pressed.connect(back_pressed.emit)
	box.add_child(back)


func _line(placeholder: String, parent: Control) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(0, 44)
	parent.add_child(edit)
	return edit


## Fills the invite in (from a link the page was opened with).
func prefill_code(code: String) -> void:
	_code_edit.text = code


func show_message(text: String) -> void:
	_status.text = text


func player_name() -> String:
	var typed := _name_edit.text.strip_edges()
	return typed if not typed.is_empty() else "Player"


func _on_host() -> void:
	_save_name()
	host_requested.emit(player_name())


func _on_join() -> void:
	var text := _code_edit.text.strip_edges()
	if text.is_empty():
		_status.text = "Enter a room code or paste an invite first."
		return
	_save_name()
	join_requested.emit(player_name(), text)


func _saved_name() -> String:
	var file := ConfigFile.new()
	if file.load(NAME_FILE) == OK:
		return str(file.get_value("player", "name", ""))
	return ""


func _save_name() -> void:
	var file := ConfigFile.new()
	file.set_value("player", "name", _name_edit.text.strip_edges())
	file.save(NAME_FILE)
