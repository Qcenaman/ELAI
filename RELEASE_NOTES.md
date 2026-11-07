Aligned with the desktop's new coder-only setup.

**Changed**
- The one model is now **Qwen3.8-27B dense UD-Q6_K** (`unsloth/Qwen3.8-27B-GGUF`, 22 GB, fully on the RTX 5090, 64K context, thinking on, 1 slot). The planner (Qwen3.6-35B-A3B) and the MoE coder (Qwen3-Coder-Next) are gone from `elai.json`, the OpenCode template (no `elai/planner`, no `elai-reviewer` agent) and the generated preset.
- `make-preset.ps1` honors an explicit `gpuLayers` per model; the generated `models.ini` / `start-hub.cmd` now produce exactly the settings of the desktop shortcuts (`D:\ELAI\launchers\coder-64k.ini`, `--models-max 1`).
- Tests follow the single-model layout.

**Measured on the desktop (from the coding-agents chat)**: 24.3 of 32.6 GB VRAM, 55-63 tok/s generation, ~2,960 tok/s prompt, tool calls OK, 50K-token prompt handled.
