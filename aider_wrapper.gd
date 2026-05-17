@tool
extends EditorPlugin

var panel
const TOOL_PANEL = preload("res://addons/aider_wrapper/tool_panel.tscn")

var _console: VBoxContainer
const AIDER_CONSOLE = preload("res://addons/aider_wrapper/aider_console.gd")

var _trigger1_thread: Thread = null

# Background thread used by Trigger2 so the editor doesn't freeze while
# ask_question.py runs (OS.execute is synchronous).
var _trigger2_thread: Thread = null

# Tail-the-log machinery. While the worker thread runs, a dedicated tail
# Thread polls the log file every _LOG_TAIL_INTERVAL_MS milliseconds and
# posts a read+push back to the main thread via Callable.call_deferred so the
# panel's Output TextEdit gets updated live with Python's stdout/stderr.
# (Timer-based polling didn't fire reliably from inside an EditorPlugin in
# editor context, hence the second Thread.)
const _LOG_TAIL_INTERVAL_MS: int = 1000
var _log_tail_thread: Thread = null
var _log_tail_running: bool = false
var _log_file_path: String = ""
var _last_selected_paths: Array[String] = []

func _enable_plugin() -> void:
	pass


func _disable_plugin() -> void:
	pass


func _enter_tree() -> void:
	panel = TOOL_PANEL.instantiate()
	panel.custom_minimum_size = Vector2(10, 0)
	var trigger2_button: Button = panel.get_node(^"%Trigger2")
	trigger2_button.pressed.connect(_on_trigger2_pressed)
	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_BL, panel)

	_console = AIDER_CONSOLE.new()
	_console.name = "AiderConsole"
	add_control_to_bottom_panel(_console, "Aider Console")

	_trigger_installing()


func _exit_tree() -> void:
	_finalize_trigger1_thread()
	_finalize_trigger2_thread()
	_finalize_log_tail()
	if is_instance_valid(panel):
		remove_control_from_docks(panel)
		panel.queue_free()
		panel = null
	if is_instance_valid(_console):
		remove_control_from_bottom_panel(_console)
		_console.queue_free()
		_console = null


func _finalize_trigger1_thread() -> void:
	if _trigger1_thread != null and _trigger1_thread.is_started():
		_trigger1_thread.wait_to_finish()
	_trigger1_thread = null


# If a Trigger2 thread is still running, block briefly to wait for it so we
# don't leak the Thread object when the plugin disables / editor closes.
func _finalize_trigger2_thread() -> void:
	if _trigger2_thread != null and _trigger2_thread.is_started():
		_trigger2_thread.wait_to_finish()
	_trigger2_thread = null


# Stop the tail thread cleanly on plugin teardown.
func _finalize_log_tail() -> void:
	_stop_log_tail()
	_log_file_path = ""


const WINDOWS_PYTHON: String = "https://www.python.org/ftp/python/3.10.0/python-3.10.0-embed-amd64.zip"
const PIP: String = "https://bootstrap.pypa.io/get-pip.py"
const INSTALL_LOG_PATH := "user://python/ask_question.log"


func download_python() -> String:
	if FileAccess.file_exists(INSTALL_LOG_PATH):
		print("[aider_wrapper] Installation marker found, skipping install.")
		return ""
	if OS.get_name() != "Windows":
		return "Only Windows For Now"

	var python_zip_path := "user://python.zip"
	var error := _download_file(WINDOWS_PYTHON, python_zip_path)
	if not error.is_empty():
		return error

	error = _download_file(PIP, "user://python/get-pip.py")
	if not error.is_empty():
		return error

	print("Saved to: ", ProjectSettings.globalize_path(python_zip_path))

	error = unzip_python(python_zip_path)
	if not error.is_empty():
		return error

	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists("python.zip"):
		var remove_err = dir.remove("python.zip")
		if remove_err != OK:
			return "Failed to remove user://python.zip: " + str(remove_err)

	error = _uncomment_import_site()
	if not error.is_empty():
		return error

	error = _install_dependencies()
	if not error.is_empty():
		return error

	error = _ensure_installation_marker()
	if not error.is_empty():
		return error

	return ""


func _download_file(url: String, dest_path: String) -> String:
	var scheme_end := url.find("://")
	if scheme_end == -1:
		return "Unsupported URL: " + url

	var scheme := url.substr(0, scheme_end).to_lower()
	var remainder := url.substr(scheme_end + 3)
	var slash_index := remainder.find("/")
	var host_part := remainder
	var request_path := "/"
	if slash_index != -1:
		host_part = remainder.substr(0, slash_index)
		request_path = remainder.substr(slash_index)

	var host := host_part
	var port := 443 if scheme == "https" else 80
	var colon_index := host_part.find(":")
	if colon_index != -1:
		host = host_part.substr(0, colon_index)
		port = int(host_part.substr(colon_index + 1))

	var client := HTTPClient.new()
	var connect_err := OK
	if scheme == "https":
		connect_err = client.connect_to_host(host, port, TLSOptions.client())
	elif scheme == "http":
		connect_err = client.connect_to_host(host, port)
	else:
		return "Unsupported URL scheme: " + scheme
	if connect_err != OK:
		return "Failed to connect to " + host + ": " + str(connect_err)

	while client.get_status() == HTTPClient.STATUS_RESOLVING or client.get_status() == HTTPClient.STATUS_CONNECTING:
		client.poll()
		OS.delay_msec(50)

	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return "Connection failed for " + url + " with status " + str(client.get_status())

	var request_err := client.request(HTTPClient.METHOD_GET, request_path, PackedStringArray())
	if request_err != OK:
		return "HTTP request failed for " + url + ": " + str(request_err)

	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		OS.delay_msec(50)

	var response_code := client.get_response_code()
	if response_code != 200:
		return "Download failed for " + url + " with status code " + str(response_code)

	var body := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.is_empty():
			OS.delay_msec(10)
		else:
			body.append_array(chunk)

	DirAccess.make_dir_recursive_absolute(dest_path.get_base_dir())
	var file := FileAccess.open(dest_path, FileAccess.WRITE)
	if file == null:
		return "Cannot save file: " + dest_path
	file.store_buffer(body)
	file.close()
	return ""


func unzip_python(zip_path: String) -> String:
	var zip = ZIPReader.new()
	var err = zip.open(zip_path)

	if err != OK:
		return "ZIP open failed: " + str(err)

	var out_dir = "user://python/"
	DirAccess.make_dir_recursive_absolute(out_dir)

	for file in zip.get_files():
		if file.ends_with("/"):
			continue

		var data = zip.read_file(file)
		var full_path = out_dir + file
		DirAccess.make_dir_recursive_absolute(full_path.get_base_dir())

		var out = FileAccess.open(full_path, FileAccess.WRITE)
		if out == null:
			zip.close()
			return "Cannot write file: " + full_path
		out.store_buffer(data)
		out.close()

	zip.close()
	print("Unzipped to: ", ProjectSettings.globalize_path(out_dir))
	return ""


func _uncomment_import_site() -> String:
	var pth_path = "user://python/python310._pth"
	if not FileAccess.file_exists(pth_path):
		return "python310._pth not found"

	var f = FileAccess.open(pth_path, FileAccess.READ)
	if f == null:
		return "Cannot open python310._pth for reading"

	var content = f.get_as_text()
	f.close()

	content = content.replace("#import site", "import site")

	f = FileAccess.open(pth_path, FileAccess.WRITE)
	if f == null:
		return "Cannot open python310._pth for writing"

	f.store_string(content)
	f.close()
	return ""

func _get_python_exe() -> String:
	return ProjectSettings.globalize_path("user://python/python.exe")


func _safe_arg(value: String) -> String:
	return "'" + value + "'"

func _install_dependencies() -> String:
	var python_exe = _get_python_exe()
	var get_pip = ProjectSettings.globalize_path("user://python/get-pip.py")

	var output := []
	var exit_code = OS.execute(python_exe, [get_pip], output, true)

	print("get-pip exit code: ", exit_code)
	for line in output:
		line = line.replace("\r", "").replace("\b", "")
		print(line)
	if exit_code != 0:
		return "pip install failed"
		
	output = []
	exit_code = OS.execute(python_exe, ["-m", "pip", "install", "uv"], output, true)

	print("install uv exit code: ", exit_code)
	for line in output:
		line = line.replace("\r", "").replace("\b", "")
		print(line)
	if exit_code != 0:
		return "install uv install failed"
	
	output = []
	exit_code = OS.execute(python_exe, ["-m", "uv", "pip", "install", "aider-chat==0.86.2"], output, true)

	print("install aider-chat exit code: ", exit_code)
	for line in output:
		line = line.replace("\r", "").replace("\b", "")
		print(line)
	if exit_code != 0:
		return "install aider-chat install failed"

	# Copy ask_question.py to python directory
	var error := _copy_file("res://addons/aider_wrapper/ask_question.py", "user://python/ask_question.py")
	if not error.is_empty():
		return error
	return ""


func _ensure_installation_marker() -> String:
	DirAccess.make_dir_recursive_absolute(INSTALL_LOG_PATH.get_base_dir())
	var file := FileAccess.open(INSTALL_LOG_PATH, FileAccess.WRITE)
	if file == null:
		return "Cannot create installation marker: " + INSTALL_LOG_PATH
	file.close()
	return ""


func _copy_file(src_path: String, dest_path: String) -> String:
	if not FileAccess.file_exists(src_path):
		return "Source file not found: " + src_path

	var src_file = FileAccess.open(src_path, FileAccess.READ)
	if src_file == null:
		return "Cannot open source file for reading: " + src_path
	var content = src_file.get_as_text()
	src_file.close()

	DirAccess.make_dir_recursive_absolute(dest_path.get_base_dir())
	var dest_file = FileAccess.open(dest_path, FileAccess.WRITE)
	if dest_file == null:
		return "Cannot create destination file: " + dest_path
	dest_file.store_string(content)
	dest_file.close()
	print("Copied file to: " + dest_path)
	return ""


func _trigger_installing() -> void:
	if _trigger1_thread != null and _trigger1_thread.is_alive():
		print("[aider_wrapper] Trigger1: installation already in progress.")
		return
	_finalize_trigger1_thread()
	_set_trigger2_disabled(true, "Installing")
	_trigger1_thread = Thread.new()
	var err := _trigger1_thread.start(_run_download_python)
	if err != OK:
		push_error("[aider_wrapper] Failed to start install thread: " + str(err))
		_trigger1_thread = null
		_set_trigger2_disabled(false, "Run")


func _run_download_python() -> void:
	var error := download_python()
	Callable(self, "_on_download_python_finished").call_deferred(error)


func _on_download_python_finished(error: String) -> void:
	_finalize_trigger1_thread()
	_set_trigger2_disabled(false, "Run")
	if error.is_empty():
		print("[aider_wrapper] Installation finished.")
		return
	push_error("[aider_wrapper] " + error)


func _get_http_status(
	result: int,
	response_code: int,
	headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	var text := body.get_string_from_utf8()

	if result == 0:
		Callable(self, "_append_to_console_output").call_deferred(text, true)

func _on_trigger2_pressed() -> void:
	if not is_instance_valid(panel):
		push_warning("[aider_wrapper] Trigger2: panel not available.")
		return
	if _trigger2_thread != null and _trigger2_thread.is_alive():
		print("[aider_wrapper] Trigger2: previous run still in progress, ignoring click.")
		return
	# Drain any finished thread from a prior run.
	_finalize_trigger2_thread()

	var selected: Array = panel.get_selected_paths()
	if selected.is_empty():
		print("[aider_wrapper] Trigger2: no files selected.")
		return
	_last_selected_paths = Array(selected, TYPE_STRING, "", null)
	print("[aider_wrapper] Trigger2: selected files (", selected.size(), "):")
	for path in selected:
		print("  ", path.replace("res://", ""))

	var python_exe = _get_python_exe()
	var ask_question = ProjectSettings.globalize_path("user://python/ask_question.py")

	var cwd = ProjectSettings.globalize_path("res://")

	var api_key: String = panel.get_api_key()
	var model: String = panel.get_selected_model()
	var prompt: String = panel.get_prompt()

	# Reset the log file: make sure user://python/ exists, delete an old log if
	# it's there, then create a fresh empty one.
	var log_resource_path := "user://python/ask_question.log"
	DirAccess.make_dir_recursive_absolute("user://python/")
	if FileAccess.file_exists(log_resource_path):
		var rm_err := DirAccess.remove_absolute(log_resource_path)
		if rm_err != OK:
			push_warning("[aider_wrapper] Could not remove old log: " + str(rm_err))
	var log_create := FileAccess.open(log_resource_path, FileAccess.WRITE)
	if log_create != null:
		log_create.close()
	else:
		push_warning("[aider_wrapper] Could not create empty log file at " + log_resource_path)
	var log_file: String = ProjectSettings.globalize_path(log_resource_path)

	# Build the argv: ask_question --cwd <cwd> --api-key <key> --message <prompt> --files file1 file2 ...
	# File paths are passed without the "res://" prefix so they're relative to cwd.
	# `_safe_arg` wraps empty strings in literal "" so OS.execute on Windows
	# doesn't drop them.
	var args: Array = [
		ask_question,
		"--cwd", cwd,
		"--api-key", _safe_arg(api_key),
		"--model", _safe_arg(model),
		"--message", _safe_arg(prompt),
		"--files"
	]
	for path in selected:
		args.append(String(path).replace("res://", ""))

	# Clear the Output box and remember which file to tail.
	_log_file_path = log_file
	if is_instance_valid(panel):
		panel.set_output_text("")
	if is_instance_valid(_console):
		_console.clear()
		make_bottom_panel_item_visible(_console)

	# Spawn a background Thread so the editor doesn't freeze. The thread runs
	# OS.execute, then posts the result back to the main thread via call_deferred.
	print("[aider_wrapper] Trigger2: starting ask_question in background thread...")
	_trigger2_thread = Thread.new()
	var err := _trigger2_thread.start(_run_ask_question.bind(python_exe, args))
	if err != OK:
		push_error("[aider_wrapper] Failed to start thread: " + str(err))
		_trigger2_thread = null
		return
	# Grey out Trigger2 until _on_ask_question_done re-enables it.
	_set_trigger2_disabled(true)
	await get_tree().create_timer(2.0).timeout
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_get_http_status)
	http.request("http://127.0.0.1:7976/logs")


# Thread entry — runs on a worker thread. Don't touch the scene tree here; we
# post results back to the main thread via Callable.call_deferred(), which
# forwards multiple typed args reliably across the thread boundary.
func _run_ask_question(python_exe: String, args: Array) -> void:
	var output: Array = []
	var cmd_line = python_exe + " " + " ".join(args)
	print(cmd_line)
	var exit_code: int = OS.execute(python_exe, args, output, true)
	Callable(self, "_on_ask_question_done").call_deferred(exit_code, output)


# Main-thread callback after the worker thread finishes.
func _on_ask_question_done(exit_code: int, output: Array) -> void:
	print("ask_question exit code: ", exit_code)
	var console_text : String = ""
	for line in output:
		var clean := String(line).replace("\r", "").replace("\b", "")
		print(clean)
		console_text = console_text + "\n" + clean
	
	Callable(self, "_append_to_console_output").call_deferred(console_text, false)
	
	if exit_code != 0:
		push_error("ask_question failed")
	# Stop tailing, do one last read so the Output box has the final log,
	# then reap the thread and re-enable the button.
	_stop_log_tail()
	_finalize_trigger2_thread()
	_set_trigger2_disabled(false)
	_refresh_selected_files()


func _refresh_selected_files() -> void:
	if _last_selected_paths.is_empty():
		return
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return
	print("[aider_wrapper] Refreshing ", _last_selected_paths.size(), " file(s)...")
	for path in _last_selected_paths:
		fs.update_file(path)
		print("[aider_wrapper]   updated: ", path)
	fs.scan()
	var open_scripts := EditorInterface.get_script_editor().get_open_scripts()
	for script in open_scripts:
		if script != null and _last_selected_paths.has(script.resource_path):
			script.reload()


func _stop_log_tail() -> void:
	_log_tail_running = false
	if _log_tail_thread != null and _log_tail_thread.is_started():
		_log_tail_thread.wait_to_finish()
	_log_tail_thread = null
	# Final main-thread read to catch anything Python wrote between the last
	# poll and exit.
	_read_and_push_log()


func _append_to_console_output(text: String, send_http_request: bool) -> void:
	if is_instance_valid(panel):
		panel.set_output_text(text)
	if is_instance_valid(_console):
		_console.set_text(text)
	if send_http_request:
		await get_tree().create_timer(5.0).timeout
		var http := HTTPRequest.new()
		add_child(http)
		http.request_completed.connect(_get_http_status)
		http.request("http://127.0.0.1:7976/logs")


# Main-thread: open the log fresh each time (no caching), read whole content,
# push into the panel and the bottom console.
func _read_and_push_log() -> void:
	if _log_file_path == "":
		return
	if not FileAccess.file_exists(_log_file_path):
		return
	var f := FileAccess.open(_log_file_path, FileAccess.READ)
	if f == null:
		return
	var content := f.get_as_text()
	f.close()
	if is_instance_valid(panel):
		panel.set_output_text(content)
	if is_instance_valid(_console):
		_console.set_text(content)


# Toggle Trigger2's disabled state. No-op if the panel is gone.
func _set_trigger2_disabled(value: bool, text: String = "Run") -> void:
	if not is_instance_valid(panel):
		return
	var btn: Button = panel.get_node_or_null(^"%Trigger2")
	if btn != null:
		btn.disabled = value
		btn.text = text
