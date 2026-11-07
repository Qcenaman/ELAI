Desktop coding setup: both Qwen models + OpenCode + ContextSaver.

**New**
- Models live in LM Studio's layout (`D:\LLM MODELS\<publisher>\<repo>\<file>.gguf`), so one download serves both the llama-server hub and LM Studio/ContextSaver.
- Per-model `enabled` flag in `desktop/elai.json`; disabled models are skipped by every script and hidden in OpenCode.
- OpenCode's MCP tools default to **ContextSaver** (made for local models); TokenSaver is only added with `install-opencode.ps1 -WithTokenSaver`. The ELAI rules file now points the local coder at the contextsaver tools.
- `get-models.ps1` downloads into the layout above; `make-preset.ps1` finds files there (or flat) automatically.

**Verified on the desktop**
- Hub with both models resident (30.6 of 32.6 GB VRAM): coder 18-34 tok/s, planner ~250 tok/s, tool calls OK on both.
- OpenCode v2.2.6 -> hub `coder` -> ContextSaver `pc` tool (scan/find) works end to end.
