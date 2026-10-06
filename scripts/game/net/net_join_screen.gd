class_name NetJoinScreen
extends Screen
## While joining: the reply to send back to whoever invited, then waiting to be connected.

signal cancelled

var _status: Label
var _reply: TextEdit
var _copy_link: Button
var _copy_code: Button
var _code := ""
var _link := ""


func _ready() -> void:
	back_enabled = false
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
	title.text = "Joining the match"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	_status = Label.new()
	_status.name = "Status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.theme_type_variation = &"PromptLabel"
	box.add_child(_status)
	_reply = TextEdit.new()
	_reply.name = "Reply"
	_reply.editable = false
	_reply.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_reply.custom_minimum_size = Vector2(0, 120)
	box.add_child(_reply)
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	_copy_link = HubStyle.button("Copy the reply link", "CopyLink")
	_copy_link.pressed.connect(func() -> void: WebPage.copy(_link))
	buttons.add_child(_copy_link)
	_copy_code = HubStyle.button("Copy the code", "CopyCode")
	_copy_code.pressed.connect(func() -> void: WebPage.copy(_code))
	buttons.add_child(_copy_code)
	var cancel := HubStyle.button("Cancel", "CancelButton")
	cancel.pressed.connect(cancelled.emit)
	box.add_child(cancel)
	show_preparing()


func show_preparing() -> void:
	_status.text = "Preparing your reply... (a few seconds)"
	_reply.text = ""
	_copy_link.disabled = true
	_copy_code.disabled = true


func show_reply(code: String, link: String) -> void:
	_code = code
	_link = link
	_status.text = "Send this reply to the host. You are connected as soon as they paste it."
	_reply.text = link
	_copy_link.disabled = false
	_copy_code.disabled = false


## Waiting for a room found through the trackers ("2/2" connected, or "" before the first).
func show_search(trackers: String) -> void:
	_reply.visible = false
	_copy_link.visible = false
	_copy_code.visible = false
	_status.text = tr("Looking for the room... The host answers as soon as they see you.")
	if not trackers.is_empty():
		_status.text += "\n" + tr("Connected relays: %s") % trackers
	_status.text += "\n" + tr("Taking long? Ask the host for an invite link instead.")


func show_message(text: String) -> void:
	_status.text = text
