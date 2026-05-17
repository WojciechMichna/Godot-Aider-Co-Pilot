# Aider Wrapper for Godot

This project adds the [Aider](https://aider.chat/) AI coding agent directly into the Godot editor, so you can automate Godot project changes without leaving your workspace.

The plugin lives in `addons/aider_wrapper` and uses OpenRouter-backed models to run Aider against the files you select inside Godot.

## What it does

- Adds a docked tool panel inside the Godot editor
- Lets you select project files from a tree view
- Sends your prompt plus selected files to Aider
- Shows live console output in the editor
- Makes Godot automation possible through OpenRouter-powered Aider runs

## Allowed models

The model list is currently fixed in `addons/aider_wrapper/tool_panel.gd`.

- `openrouter/openai/gpt-oss-120b:free`
- `openrouter/nvidia/nemotron-3-super-120b-a12b:free`
- `openrouter/arcee-ai/trinity-large-thinking:free`
- `openrouter/deepseek/deepseek-v4-flash:free`

## Videos

### Installation and usage

Changing a script with `gpt-oss`.
[Aider OpenAI.webm](https://github.com/user-attachments/assets/b0655f6b-e5c1-4cca-b91e-fd3ad40f847f)


### Entity creation demo

Adding an entity with `trinity-large-thinking`.
[Trinity Add Entity.webm](https://github.com/user-attachments/assets/1f2de28d-1464-404f-877b-4389fee10ccf)


## How the workflow looks

1. Enable the plugin in Godot.
2. Wait for the plugin to bootstrap its local Python/Aider setup.
3. Paste your OpenRouter API key into the panel.
4. Choose one of the allowed models.
5. Select the Godot project files you want Aider to work on.
6. Enter a prompt and press `Run`.

Aider then runs on the selected files and streams its output back into the Godot editor.

## OpenRouter and Godot automation

This wrapper is built around OpenRouter. The plugin collects your OpenRouter API key, passes the selected OpenRouter model to Aider, and runs code-editing tasks directly against your Godot project files.

That means you can use it for Godot automation tasks like:

- updating GDScript files
- editing scenes and config files
- applying project-wide changes to selected resources
- iterating on gameplay code from inside the editor

## Notes

- Current bootstrap/install flow is Windows-only.
- The plugin installs an embedded Python runtime and `aider-chat` automatically.
- The OpenRouter API key is stored in Godot user settings for reuse.

## Main files

- `addons/aider_wrapper/aider_wrapper.gd` - editor plugin and execution flow
- `addons/aider_wrapper/tool_panel.gd` - UI logic, file picker, and allowed model list
- `addons/aider_wrapper/ask_question.py` - Python entrypoint that launches Aider
