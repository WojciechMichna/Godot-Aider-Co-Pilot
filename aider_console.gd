@tool
extends VBoxContainer

var _text_edit: TextEdit
var _toolbar: HBoxContainer
var _clear_button: Button

func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Toolbar row (Clear button, można rozbudować)
	_toolbar = HBoxContainer.new()
	add_child(_toolbar)

	_clear_button = Button.new()
	_clear_button.text = "Clear"
	_clear_button.pressed.connect(clear)
	_toolbar.add_child(_clear_button)

	# Główny TextEdit z wyjściem
	_text_edit = TextEdit.new()
	_text_edit.editable = false
	_text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_text_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_text_edit)


func set_text(text: String) -> void:
	if _text_edit == null:
		return
	if _text_edit.text == text:
		return
	_text_edit.text = text
	_scroll_to_bottom()


func append_text(text: String) -> void:
	if _text_edit == null:
		return
	_text_edit.text += text
	_scroll_to_bottom()


func clear() -> void:
	if _text_edit != null:
		_text_edit.text = ""


func _scroll_to_bottom() -> void:
	_text_edit.scroll_vertical = _text_edit.get_line_count()
