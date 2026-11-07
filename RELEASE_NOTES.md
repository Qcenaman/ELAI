Desktop stage verified on the RTX 5090 PC.

**New**
- The launcher sets `LLAMA_CACHE` to the models dir, so models already downloaded with `-hf` (Qwen3.6-27B, gemma-4-31B, gpt-oss-120b...) are listed by the hub and loadable on demand next to `coder` and `planner`.

**Measured on the desktop (b12189, CUDA 13.5, both models resident, 29.7 of 32.6 GB VRAM)**
- `coder` (Qwen3-Coder-Next UD-Q4_K_S, experts in RAM): 23-34 tok/s generation, ~290 tok/s prompt processing, tool calls OK.
- `planner` (Qwen3.6-35B-A3B UD-Q4_K_M, all on GPU): 110-250 tok/s generation, ~11,000 tok/s prompt processing, tool calls OK.
- OpenCode v2.2.6 -> hub -> TokenSaver MCP chain works end to end.
