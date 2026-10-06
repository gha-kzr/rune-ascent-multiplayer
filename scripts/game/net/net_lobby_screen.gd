class_name NetLobbyScreen
extends Screen
## Before the fight: who is here, which hero and side each player picks, the map (the host's choice, shown
## from above), the turn timer and the grace time, a way to invite more players, and the host's Start.
## Everything a player changes goes through the match session, so every screen shows the same lobby.

signal invite_requested(for_seat: int)
signal reply_pasted(text: String)
signal leave_requested

var session: MatchSession

var _banner: Label
var _name_edit: LineEdit
var _room_label: Label
var _room_link := ""
var _room_code := ""
var _copy_room: Button
var _players: VBoxContainer
var _typology: OptionButton
var _size: SpinBox
var _seed: LineEdit
var _turn: SpinBox
var _grace: SpinBox
var _preview: MapPreview
var _preview_key := ""
var _invite_for: OptionButton
var _invite_button: Button
var _invite_status: Label
var _invite_link: TextEdit
var _copy_link: Button
var _copy_code: Button
var _reply: TextEdit
var _connect: Button
var _start: Button
var _leave: Button
var _code := ""
var _link := ""
var _settings_fields: Array[Control] = []


func bind(match_session: MatchSession) -> void:
	session = match_session
	_build()
	session.changed.connect(refresh)
	refresh()


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color(0.1, 0.11, 0.14)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 10)
	margin.add_child(rows)
	var title := Label.new()
	title.theme_type_variation = &"HeaderLabel"
	title.text = "Match lobby"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rows.add_child(title)
	_banner = Label.new()
	_banner.name = "Banner"
	_banner.theme_type_variation = &"PromptLabel"
	_banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(_banner)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rows.add_child(scroll)
	var main := HBoxContainer.new()
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 24)
	scroll.add_child(main)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.add_child(left)
	_name_edit = LineEdit.new()
	_name_edit.name = "NameEdit"
	_name_edit.placeholder_text = "Your name"
	_name_edit.max_length = MatchState.MAX_NAME
	_name_edit.text_submitted.connect(func(text: String) -> void: _rename(text))
	_name_edit.focus_exited.connect(func() -> void: _rename(_name_edit.text))
	left.add_child(_name_edit)
	var players_title := Label.new()
	players_title.theme_type_variation = &"PromptLabel"
	players_title.text = "Players"
	left.add_child(players_title)
	_players = VBoxContainer.new()
	_players.name = "Players"
	left.add_child(_players)
	_build_invite(left)
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(340, 0)
	main.add_child(right)
	_build_settings(right)
	var bottom := HBoxContainer.new()
	rows.add_child(bottom)
	_leave = HubStyle.button("Leave", "LeaveButton")
	_leave.pressed.connect(leave_requested.emit)
	bottom.add_child(_leave)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(spacer)
	_start = HubStyle.button("Start the match", "StartButton")
	_start.custom_minimum_size = Vector2(220, 48)
	_start.pressed.connect(func() -> void: session.start_match())
	bottom.add_child(_start)


func _build_settings(parent: Control) -> void:
	var title := Label.new()
	title.theme_type_variation = &"PromptLabel"
	title.text = "Map and rules"
	parent.add_child(title)
	_preview = MapPreview.new()
	_preview.custom_minimum_size = Vector2(320, 320)
	parent.add_child(_preview)
	_typology = OptionButton.new()
	_typology.name = "Typology"
	for index in MatchState.TYPOLOGIES.size():
		_typology.add_item(_typology_name(MatchState.TYPOLOGIES[index]), index)
	_typology.item_selected.connect(func(index: int) -> void: session.configure("typology", MatchState.TYPOLOGIES[index]))
	_labelled(tr("Map shape"), _typology, parent)
	_size = _spin(PvpMap.MIN_SIZE, PvpMap.MAX_SIZE, "Size")
	_size.value_changed.connect(func(value: float) -> void: session.configure("size", int(value)))
	_labelled(tr("Map size"), _size, parent)
	_seed = LineEdit.new()
	_seed.name = "Seed"
	_seed.custom_minimum_size = Vector2(120, 0)
	_seed.text_submitted.connect(_on_seed_text)
	_seed.focus_exited.connect(func() -> void: _on_seed_text(_seed.text))
	var new_seed := HubStyle.button("New map", "NewSeed")
	new_seed.pressed.connect(func() -> void: session.configure("seed", randi_range(1, 999999)))
	var seed_row := HBoxContainer.new()
	seed_row.add_child(_seed)
	seed_row.add_child(new_seed)
	_labelled(tr("Map number"), seed_row, parent)
	_turn = _spin(10, 120, "Turn")
	_turn.value_changed.connect(func(value: float) -> void: session.configure("turn", int(value)))
	_labelled(tr("Seconds per turn"), _turn, parent)
	_grace = _spin(0, 120, "Grace")
	_grace.value_changed.connect(func(value: float) -> void: session.configure("grace", int(value)))
	_labelled(tr("Seconds before the AI replaces a player who left"), _grace, parent)
	_settings_fields = [_typology, _size, _seed, new_seed, _turn, _grace]


func _build_invite(parent: Control) -> void:
	var title := Label.new()
	title.theme_type_variation = &"PromptLabel"
	title.text = "Invite players"
	parent.add_child(title)
	_room_label = Label.new()
	_room_label.name = "RoomCode"
	_room_label.theme_type_variation = &"PromptLabel"
	_room_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_room_label.hide()
	parent.add_child(_room_label)
	_copy_room = HubStyle.button("Copy the room link", "CopyRoom")
	_copy_room.pressed.connect(func() -> void: WebPage.copy(_room_link))
	_copy_room.hide()
	parent.add_child(_copy_room)
	var how := Label.new()
	how.theme_type_variation = &"SmallLabel"
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	how.text = "Friends can join with the room code. If that doesn't work for them (a strict network), make an invite, send the link, then paste the reply they send back: each player needs their own invite."
	parent.add_child(how)
	var row := HBoxContainer.new()
	parent.add_child(row)
	_invite_for = OptionButton.new()
	_invite_for.name = "InviteFor"
	row.add_child(_invite_for)
	_invite_button = HubStyle.button("Make an invite", "InviteButton")
	_invite_button.pressed.connect(_on_invite)
	row.add_child(_invite_button)
	_invite_status = Label.new()
	_invite_status.name = "InviteStatus"
	_invite_status.theme_type_variation = &"SmallLabel"
	_invite_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(_invite_status)
	_invite_link = TextEdit.new()
	_invite_link.name = "InviteLink"
	_invite_link.editable = false
	_invite_link.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_invite_link.custom_minimum_size = Vector2(0, 90)
	_invite_link.hide()
	parent.add_child(_invite_link)
	var copy_row := HBoxContainer.new()
	parent.add_child(copy_row)
	_copy_link = HubStyle.button("Copy the invite link", "CopyInviteLink")
	_copy_link.pressed.connect(func() -> void: WebPage.copy(_link))
	_copy_link.hide()
	copy_row.add_child(_copy_link)
	_copy_code = HubStyle.button("Copy the code", "CopyInviteCode")
	_copy_code.pressed.connect(func() -> void: WebPage.copy(_code))
	_copy_code.hide()
	copy_row.add_child(_copy_code)
	_reply = TextEdit.new()
	_reply.name = "ReplyEdit"
	_reply.placeholder_text = "Paste the reply link or code here"
	_reply.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_reply.custom_minimum_size = Vector2(0, 70)
	_reply.hide()
	parent.add_child(_reply)
	_connect = HubStyle.button("Connect the player", "ConnectButton")
	_connect.pressed.connect(func() -> void: reply_pasted.emit(_reply.text))
	_connect.hide()
	parent.add_child(_connect)


func _spin(low: int, high: int, node_name: String) -> SpinBox:
	var spin := SpinBox.new()
	spin.name = node_name
	spin.min_value = low
	spin.max_value = high
	spin.step = 1
	return spin


func _labelled(text: String, control: Control, parent: Control) -> void:
	var label := Label.new()
	label.theme_type_variation = &"SmallLabel"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.text = text
	parent.add_child(label)
	parent.add_child(control)


static func _typology_name(file: String) -> String:
	return TranslationServer.translate(file.replace("_", " ").capitalize())


# --- Showing the lobby ----------------------------------------------------------------------

func refresh() -> void:
	if session == null:
		return
	var state := session.state
	var is_host := session.is_host()
	var in_lobby := state.phase == MatchState.Phase.LOBBY
	_refresh_players(in_lobby)
	_refresh_settings(is_host and in_lobby)
	_refresh_invite_options(in_lobby)
	_start.visible = is_host
	_start.disabled = not in_lobby or not state.start_problem().is_empty()
	_start.tooltip_text = state.start_problem()
	if not in_lobby:
		_banner.text = tr("The match is over: waiting for the host to open a new lobby.") if state.is_over() else tr("The match is going on.")
	elif not is_host:
		_banner.text = tr("Waiting for the host to start. Pick your hero and side, then press Ready.")
	else:
		var problem := state.start_problem()
		_banner.text = tr("You are the host: start when everyone is ready.") if problem.is_empty() else tr("You are the host. Not ready to start yet: %s.") % problem


func _rename(text: String) -> void:
	var mine := session.state.seats.get(session.my_id) as MatchState.Seat
	var clean := text.strip_edges()
	if mine != null and not clean.is_empty() and clean != mine.name:
		session.set_field("name", clean)


func _refresh_players(in_lobby: bool) -> void:
	var me := session.state.seats.get(session.my_id) as MatchState.Seat
	_name_edit.visible = in_lobby and me != null
	if me != null and not _name_edit.has_focus():
		_name_edit.text = me.name
	HubStyle.clear_children(_players)
	for id in session.state.seat_ids():
		var seat := session.state.seats[id]
		var mine := id == session.my_id
		var row := HBoxContainer.new()
		row.name = "Seat%d" % id
		var name_label := Label.new()
		name_label.custom_minimum_size = Vector2(190, 0)
		name_label.clip_text = true
		name_label.text = _seat_text(seat, mine, id == session.host_id)
		name_label.add_theme_color_override("font_color", NetStatusPanel.SIDE_COLORS[seat.side])
		row.add_child(name_label)
		if mine and in_lobby:
			row.add_child(_hero_picker(seat))
			row.add_child(_side_buttons(seat))
			var ready := CheckBox.new()
			ready.name = "Ready"
			ready.text = "Ready"
			ready.button_pressed = seat.ready
			ready.toggled.connect(func(on: bool) -> void: session.set_ready(on))
			row.add_child(ready)
		else:
			var info := Label.new()
			info.text = "%s · %s%s" % [PvpHeroes.hero_name(seat.hero), tr("Side A") if seat.side == 0 else tr("Side B"), " · " + tr("ready") if seat.ready and in_lobby else ""]
			row.add_child(info)
		_players.add_child(row)


func _seat_text(seat: MatchState.Seat, mine: bool, host: bool) -> String:
	var text := seat.name
	if mine:
		text += " " + tr("(you)")
	if host:
		text += " " + tr("(host)")
	if not seat.connected:
		text += " " + tr("(away)")
	return text


func _hero_picker(seat: MatchState.Seat) -> OptionButton:
	var picker := OptionButton.new()
	picker.name = "Hero"
	for index in PvpHeroes.hero_count():
		picker.add_item(PvpHeroes.hero_name(index), index)
	picker.select(seat.hero)
	picker.item_selected.connect(func(index: int) -> void: session.set_field("hero", index))
	return picker


func _side_buttons(seat: MatchState.Seat) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.name = "Side"
	for side in 2:
		var button := Button.new()
		button.name = "Side%s" % ("A" if side == 0 else "B")
		button.text = tr("Side A") if side == 0 else tr("Side B")
		button.toggle_mode = true
		button.button_pressed = seat.side == side
		button.pressed.connect(func() -> void: session.set_field("side", side))
		box.add_child(button)
	return box


func _refresh_settings(editable: bool) -> void:
	var settings := session.state.settings
	_typology.select(MatchState.TYPOLOGIES.find(settings["typology"]))
	_size.set_value_no_signal(settings["size"])
	if not _seed.has_focus():
		_seed.text = str(settings["seed"])
	_turn.set_value_no_signal(settings["turn"])
	_grace.set_value_no_signal(settings["grace"])
	for field in _settings_fields:
		if field is OptionButton:
			(field as OptionButton).disabled = not editable
		elif field is SpinBox:
			(field as SpinBox).editable = editable
		elif field is LineEdit:
			(field as LineEdit).editable = editable
		elif field is Button:
			(field as Button).disabled = not editable
	var key := "%s/%d/%d" % [settings["typology"], settings["size"], settings["seed"]]
	if key != _preview_key:
		_preview_key = key
		var typology := load("res://data/maps/typologies/%s.tres" % settings["typology"]) as MapTypology
		_preview.show_map(PvpMap.generate(int(settings["seed"]), typology, int(settings["size"])))


func _on_seed_text(text: String) -> void:
	if session.is_host() and text.is_valid_int() and int(text) != int(session.state.settings["seed"]):
		session.configure("seed", int(text))


## The invite choices: a new player (while in the lobby) or each player who is away.
func _refresh_invite_options(in_lobby: bool) -> void:
	var previous := _invite_for.get_selected_id() if _invite_for.item_count > 0 else -1
	_invite_for.clear()
	if in_lobby:
		_invite_for.add_item(tr("A new player"), -1)
	for id in session.state.seat_ids():
		var seat := session.state.seats[id]
		if not seat.connected:
			_invite_for.add_item(tr("%s coming back") % seat.name, id)
	if _invite_for.item_count == 0:
		_invite_for.add_item(tr("(nobody to invite)"), -2)
	var index := _invite_for.get_item_index(previous)
	_invite_for.select(index if index >= 0 else 0)
	_invite_button.disabled = _invite_for.get_selected_id() == -2


func _on_invite() -> void:
	_invite_status.text = tr("Preparing the invite... (a few seconds)")
	_invite_link.hide()
	_copy_link.hide()
	_copy_code.hide()
	invite_requested.emit(_invite_for.get_selected_id())


## The invite is ready: show its link and the box for the reply.
func show_invite(code: String, link: String) -> void:
	_code = code
	_link = link
	_invite_status.text = tr("Send this link to the player. When they send a reply back, paste it below.")
	_invite_link.text = link
	_invite_link.show()
	_copy_link.show()
	_copy_code.show()
	_reply.text = ""
	_reply.show()
	_connect.show()


## The room code, to read out or share as a link (anyone who has it can join).
func show_room(code: String, link: String) -> void:
	_room_code = code
	_room_link = link
	_room_label.text = tr("Room code: %s") % RoomCode.pretty(code)
	_room_label.show()
	_copy_room.show()


func show_invite_message(text: String) -> void:
	_invite_status.text = text
