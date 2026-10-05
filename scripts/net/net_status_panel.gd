class_name NetStatusPanel
extends PanelContainer
## In the fight: who plays which hero (a colour for the side), who is a player, who the AI and who has
## dropped out, the seconds left on the turn, and a button to let the AI play my hero (or take it back).

const SIDE_COLORS: Array[Color] = [Color(0.45, 0.65, 1.0), Color(1.0, 0.5, 0.45)]

var _session: MatchSession
var _rows: VBoxContainer
var _timer_label: Label
var _toggle: Button


func bind(session: MatchSession) -> void:
	_session = session
	mouse_filter = Control.MOUSE_FILTER_PASS
	theme_type_variation = &"Chip"
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	offset_left = 12.0
	offset_top = 12.0
	var box := VBoxContainer.new()
	add_child(box)
	var title := Label.new()
	title.theme_type_variation = &"PromptLabel"
	title.text = tr("Players")
	box.add_child(title)
	_rows = VBoxContainer.new()
	box.add_child(_rows)
	_timer_label = Label.new()
	_timer_label.theme_type_variation = &"SmallLabel"
	box.add_child(_timer_label)
	_toggle = Button.new()
	_toggle.focus_mode = Control.FOCUS_NONE
	_toggle.pressed.connect(_on_toggle)
	box.add_child(_toggle)
	session.changed.connect(refresh)
	refresh()


func _process(_delta: float) -> void:
	if _session == null:
		return
	var left := _session.turn_seconds_left()
	_timer_label.visible = left >= 0.0
	_timer_label.text = tr("Turn: %d s") % ceili(left)


func refresh() -> void:
	if _session == null:
		return
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	for id in _session.state.seat_ids():
		var seat := _session.state.seats[id]
		var row := Label.new()
		row.theme_type_variation = &"SmallLabel"
		row.add_theme_color_override("font_color", SIDE_COLORS[seat.side])
		row.text = describe(seat, id == _session.my_id)
		_rows.add_child(row)
	var mine := _session.state.seats.get(_session.my_id) as MatchState.Seat
	_toggle.visible = mine != null
	if mine != null:
		_toggle.text = tr("Play my hero again") if mine.ai else tr("Let the AI play my hero")


## "Alice: Knight", with the tag that matters: (AI), (away) or (you).
static func describe(seat: MatchState.Seat, is_me: bool) -> String:
	var text := "%s: %s" % [seat.name, PvpHeroes.hero_name(seat.hero)]
	if seat.ai:
		text += " " + TranslationServer.translate("(AI)")
	elif not seat.connected:
		text += " " + TranslationServer.translate("(away)")
	elif is_me:
		text += " " + TranslationServer.translate("(you)")
	return text


func _on_toggle() -> void:
	var mine := _session.state.seats.get(_session.my_id) as MatchState.Seat
	if mine != null:
		_session.hand_to_ai(not mine.ai)
