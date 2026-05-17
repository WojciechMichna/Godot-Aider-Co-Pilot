@tool
extends Control

# Populates the Tree with project files (under res://) using checkbox cells so
# the user can mark which files to act on. Buttons (Trigger1/Trigger2) are
# wired up by aider_wrapper.gd — call `populate_tree()` / `get_selected_paths()`
# from there to interact with this panel.
#
# The tree auto-refreshes when EditorFileSystem signals a change (file added,
# removed, renamed, or modified). We snapshot the currently-checked paths
# before rebuilding so the user's selection survives the refresh.

# Folders / files starting with "." are always skipped. Any path in SKIP_DIRS
# is also skipped.
const SKIP_DIRS: PackedStringArray = [
	"res://.godot",
	"res://.git",
	"res://.import",
]

# Files with these extensions are listed. Empty list means "all files".
const INCLUDE_EXTENSIONS: PackedStringArray = [
	"gd", "cs", "tscn", "tres", "gdshader", "json", "cfg", "txt", "md",
]
const MODEL_OPTIONS: PackedStringArray = [
	"openrouter/openai/gpt-oss-120b:free",
	"openrouter/nvidia/nemotron-3-super-120b-a12b:free",
	"openrouter/arcee-ai/trinity-large-thinking:free",
	"openrouter/deepseek/deepseek-v4-flash:free",
]

@onready var file_tree: Tree = $VBoxContainer/Tree
@onready var api_key_input: LineEdit = $VBoxContainer/ApiKeyInput
@onready var model_select: OptionButton = $VBoxContainer/ModelSelect
@onready var prompt_input: TextEdit = $VBoxContainer/Prompt
@onready var output_view: TextEdit = $VBoxContainer/Output

# Cached paths to re-check after a rebuild. Set by populate_tree() before it
# clears the tree and consumed by _scan_directory() while rebuilding.
var _restore_checked: PackedStringArray = []

const _CONFIG_PATH := "user://aider_wrapper/settings.cfg"
const _CONFIG_SECTION := "api"
const _CONFIG_KEY_API_KEY := "api_key"


func _save_api_key() -> void:
	var cfg := ConfigFile.new()
	# Load existing config first so we don't overwrite other keys.
	cfg.load(_CONFIG_PATH)
	cfg.set_value(_CONFIG_SECTION, _CONFIG_KEY_API_KEY, api_key_input.text)
	DirAccess.make_dir_recursive_absolute(_CONFIG_PATH.get_base_dir())
	cfg.save(_CONFIG_PATH)


func _load_api_key() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_CONFIG_PATH) == OK:
		api_key_input.text = cfg.get_value(_CONFIG_SECTION, _CONFIG_KEY_API_KEY, "")


func _ready() -> void:
	_populate_model_select()
	_load_api_key()
	api_key_input.text_changed.connect(func(_new_text: String) -> void: _save_api_key())
	populate_tree()
	# Hook into the editor filesystem so the tree refreshes itself when files
	# are added/removed/renamed. Only valid in editor context.
	if Engine.is_editor_hint():
		var fs := EditorInterface.get_resource_filesystem()
		if fs != null:
			# filesystem_changed: emitted after a rescan that detected changes
			# (e.g. a new file appeared, file deleted, renamed). This is the
			# main hook that handles "user created a new file in the project".
			if not fs.filesystem_changed.is_connected(_on_filesystem_changed):
				fs.filesystem_changed.connect(_on_filesystem_changed)
			# sources_changed: belt-and-suspenders — fires when EditorFileSystem
			# starts/finishes processing source changes. Some Godot versions
			# fire one signal but not the other depending on context.
			if not fs.sources_changed.is_connected(_on_sources_changed):
				fs.sources_changed.connect(_on_sources_changed)


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		var fs := EditorInterface.get_resource_filesystem()
		if fs != null:
			if fs.filesystem_changed.is_connected(_on_filesystem_changed):
				fs.filesystem_changed.disconnect(_on_filesystem_changed)
			if fs.sources_changed.is_connected(_on_sources_changed):
				fs.sources_changed.disconnect(_on_sources_changed)


# --- Public API (called from aider_wrapper.gd or anywhere else) ---

func populate_tree() -> void:
	# Capture currently-checked paths before clearing so we can restore them.
	_restore_checked = PackedStringArray(get_selected_paths())
	file_tree.clear()
	var root := file_tree.create_item()
	root.set_text(0, "res://")
	_scan_directory("res://", root)


func get_selected_paths() -> Array[String]:
	var selected: Array[String] = []
	if file_tree != null and file_tree.get_root() != null:
		_collect_checked(file_tree.get_root(), selected)
	return selected


func get_api_key() -> String:
	if api_key_input == null:
		return ""
	return api_key_input.text


func get_prompt() -> String:
	if prompt_input == null:
		return ""
	return prompt_input.text


func get_selected_model() -> String:
	if model_select == null or model_select.item_count == 0:
		return ""
	return model_select.get_item_text(model_select.selected)


# Replace the contents of the "Output" TextEdit and scroll to the bottom.
# Used by aider_wrapper.gd to mirror the live ask_question.log into the panel
# while the background thread is running.
func set_output_text(text: String) -> void:
	if output_view == null:
		return
	if output_view.text == text:
		return  # nothing changed since last tick
	output_view.text = text
	# Auto-scroll to the latest line.
	output_view.scroll_vertical = output_view.get_line_count()


# Append text to the Output TextEdit and scroll to the bottom.
func append_output_text(text: String) -> void:
	if output_view == null:
		return
	output_view.text += text
	output_view.scroll_vertical = output_view.get_line_count()


# --- Internals ---

func _populate_model_select() -> void:
	if model_select == null:
		return
	model_select.clear()
	for model_name in MODEL_OPTIONS:
		model_select.add_item(model_name)
	if model_select.item_count > 0:
		model_select.select(0)

func _on_filesystem_changed() -> void:
	# EditorFileSystem fires this after a rescan that found a real change
	# (file added, removed, renamed, modified). Refresh the tree.
	print("[aider_wrapper] filesystem_changed -> rebuilding file tree")
	populate_tree()


func _on_sources_changed(_exist: bool) -> void:
	# Backup signal — fires when EditorFileSystem starts/finishes processing
	# source changes. Refresh in case filesystem_changed didn't reach us.
	print("[aider_wrapper] sources_changed -> rebuilding file tree")
	populate_tree()


func _scan_directory(path: String, parent_item: TreeItem) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var folders: Array[String] = []
	var files: Array[String] = []
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			if dir.current_is_dir():
				var full := path.path_join(entry)
				if not SKIP_DIRS.has(full):
					folders.append(entry)
			else:
				files.append(entry)
		entry = dir.get_next()
	dir.list_dir_end()

	folders.sort()
	files.sort()

	# Folders first (collapsed by default), then files at this level.
	for f in folders:
		var folder_item := file_tree.create_item(parent_item)
		folder_item.set_text(0, f + "/")
		folder_item.collapsed = true
		_scan_directory(path.path_join(f), folder_item)

	for f in files:
		var ext := f.get_extension().to_lower()
		if not INCLUDE_EXTENSIONS.is_empty() and not INCLUDE_EXTENSIONS.has(ext):
			continue
		var full_path := path.path_join(f)
		var file_item := file_tree.create_item(parent_item)
		file_item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		file_item.set_text(0, f)
		file_item.set_editable(0, true)
		file_item.set_metadata(0, full_path)
		# Restore previous check state if this file was selected before refresh.
		if _restore_checked.has(full_path):
			file_item.set_checked(0, true)


func _collect_checked(item: TreeItem, out: Array[String]) -> void:
	if item == null:
		return
	if item.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK and item.is_checked(0):
		var meta = item.get_metadata(0)
		if meta != null:
			out.append(str(meta))
	var child := item.get_first_child()
	while child != null:
		_collect_checked(child, out)
		child = child.get_next()
