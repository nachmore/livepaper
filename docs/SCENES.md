# Built-in scenes

LivePaper ships five example scenes in `Scenes/` (bundled as `LivePaper.app/Contents/Resources/Scenes`,
listed as *built-in* in the library). Each one was written by an AI coding agent through LivePaper's
own pipeline — `livepaper ai create "<prompt>" --harness <h>`, then `livepaper ai modify` rounds
with art-direction feedback after a person reviewed the stills — and every version passed
`livepaper check` before it was accepted. The prompts, the harness and model of every round and the
agent's own summary are recorded in each scene's `history.jsonl`. All art is procedural and original.

Budgets below are from the final `livepaper check --power` (frame time at the heaviest sampled
moment; energy is the render process's CPU energy at the battery profile, 30 fps and 75 % scale).

| Scene | | Made with (in order) | Frame time 1512×982@2 · 5120×1440@1 | Energy | Brightness (frame · clock) |
|---|---|---|---|---|---|
| **Abyssal Lanterns** `abyssal-lanterns` | Translucent bioluminescent drifters — bells, fringed discs, frilly-armed and comb jellies — pulse and travel through the deep night ocean, with marine snow and passing waves of plankton light. | Claude Code (claude-opus-5-5) ×3 | 2.47 · 3.36 ms | 135 mW | 11–18 · 15–20 |
| **Ink and Ember** `ink-and-ember` | A sumi-e mountain range at dusk on dark handmade paper: feathered ink washes and karst towers floating on drifting mist, a leaning pine on a near crag, and a seal-red sun on a slow arc behind the ridges. | Codex (openai.gpt-5.6-luna) ×2, Codex (openai.gpt-5.6-sol) ×2, Claude Code (claude-opus-5-5) | 0.53 · 0.56 ms | 26 mW | 40–42 · 23–28 |
| **Liquid Glass** `liquid-glass` | Deep midnight, violet and teal colour fields behind a thick pane of curved glass, with a flowing ember ribbon, faint chromatic fringes and delicate pool caustics (WebGL). | Kiro CLI (claude-opus-5.5) ×2, Claude Code (claude-opus-5-5) | 1.70 · 2.27 ms | 24 mW¹ | 39–49 · 2–16 |
| **Rain on the River** `rain-on-the-river` | A night skyline of original towers in soft rain across a wide river: hazy depth layers, a lit cable-stayed bridge, slow aviation lights and long, wavering reflections. | Claude Code (claude-opus-5-5), Kiro CLI (claude-opus-5.5), Claude Code | 2.04 · 2.47 ms | 56 mW | 21–23 · 9–15 |
| **Ringed Giant** `ringed-giant` | A banded gas giant with wide, tilted rings slowly turns under a distant star, moons drifting past, a faint nebula across the far side of the sky. | Codex (openai.gpt-5.6-luna) ×2, Codex (openai.gpt-5.6-sol), Claude Code (claude-opus-5-5) | 0.75 · 0.89 ms | 36 mW | 20–24 · 3–5 |

Budgets: ≤ 4 ms at 1512×982@2, ≤ 6 ms at 5120×1440@1, ≤ 300 mW (aim < 150), mean brightness ≤ 165
and ≤ 120 behind the clock (0–255). ¹ WebGL work runs on the GPU, which the CPU-energy figure doesn't
include.

## Adding or updating a built-in scene

1. Author it in a scratch library: `LIVEPAPER_HOME=$(mktemp -d) livepaper ai create "…" --harness …`
   and refine with `livepaper ai modify <id> "…"` until the stills in `.check/` are excellent at
   32:9, 16:10, 5:4, thumbnail size and t = 600.
2. On the library copy: `livepaper check <pkg> --power` (records `performance` in `scene.json`) and
   `livepaper thumbnail <pkg> [--t <moment>]` (the app renders thumbnails only for the user's own
   scenes, so built-ins ship `thumbnail.jpg`).
3. Copy `scene.json`, `scene.js`, `thumbnail.jpg`, `history.jsonl` (and `assets/`, if any) into
   `Scenes/<id>.lpscene/` — not `.check/` or `history/` — and list it here.
4. `swift run LivePaperSelfTest scenes.` checks the packages: manifest, compile, recorded budgets,
   thumbnail, provenance, no machine-specific paths, and that this page lists every scene.
