# tern-agents

Run any coding-agent CLI — Claude Code, Codex, Gemini, OpenCode, Cursor Agent, Aider, or anything custom — as a native [Tern](https://stencil.so/tern) agent block, with named run presets such as `claude --dangerously-skip-permissions`.

Tern's own **New agent block** runs one command (the `agent_command` setting, `omp` by default). This plugin adds agent profiles, per-agent presets, a launcher, quick entry and a Carly/plugin export on top of the same agent-block machinery.

## Status

Work in progress (0.1.0). Built against Tern's Luau plugin API as shipped in Tern 0.5.2 (`tern.d.luau` in this repo, written by `tern plugin types`). Tern is in closed beta and its plugin API is unversioned. See [DESIGN.md](DESIGN.md).

## Install

```bash
git clone https://github.com/maxtuzz/tern-agents ~/src/tern-agents
tern plugin link ~/src/tern-agents
tern plugin reload
```

## Offline docs

`docs/` mirrors the Tern plugin SDK documentation from https://docs.stencil.so/tern (Markdown form), for agents and offline reading.

## License

MIT
