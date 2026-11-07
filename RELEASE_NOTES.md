First stage: the desktop inference hub.

**New**
- `desktop/setup.ps1` one-shot setup (run elevated): installs a pinned llama.cpp nightly (b12189, CUDA 13.5 with bundled cudart; falls back to CUDA 12.4, then Vulkan), downloads Qwen3-Coder-Next UD-Q4_K_S (46 GB) and Qwen3.6-35B-A3B UD-Q4_K_M (21 GB), generates the router preset (`models.ini`) and launcher (`start-hub.cmd`), opens the firewall for LAN + Tailscale, starts the hub and runs a smoke test.
- Both models stay resident on the RTX 5090: planner fully on GPU (3 slots x 64K), coder with experts in system RAM (2 slots x 64K); KV cache q8_0; model ids `coder` and `planner` at `http://<desktop>:8080/v1`.
- `start-hub.ps1` / `stop-hub.ps1` / `hub-test.ps1` (status, tok/s, tool-call check, VRAM). The launcher is TokenSaver-compatible (`ai_script`).
- `install-opencode.ps1`: OpenCode V2 standalone build + global config with the hub provider (`elai/coder`, `elai/planner`, `#fast` variant), TokenSaver as MCP, `elai-coder` / `elai-reviewer` agents and the ELAI rules file.
- Pester tests for settings, preset generation, config merge and PowerShell 5.1 compatibility; CI on every push (pwsh + Windows PowerShell 5.1); releases are tagged automatically from `VERSION` + `RELEASE_NOTES.md` once CI is green.
