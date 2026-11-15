# Built-in scenes

LivePaper ships five example scenes in `Scenes/` (bundled as `LivePaper.app/Contents/Resources/Scenes`,
listed as *built-in* in the library). Each one was written by an AI coding agent through LivePaper's
own pipeline — `livepaper ai create "<prompt>" --harness <h>`, then `livepaper ai modify` rounds
with art-direction feedback after a person reviewed the stills — and every version passed
`livepaper check` before it was accepted. The prompts, the harness and model of every round and the
agent's own summary are recorded in each scene's `history.jsonl`. All art is procedural and original.

Budgets below are from the final `livepaper check --power` (frame time at the heaviest sampled
moment; energy is the render process's CPU energy at the battery profile, 30 fps and 75 % scale;
motion is the share of the frame that visibly changes within 5 s and within 2 s, at 16:9 and 5:4).

| Scene | | Made with (in order) | Frame time 1512×982@2 · 5120×1440@1 | Energy | Brightness (frame · clock) | Motion within 5 s · 2 s (16:9 / 5:4) |
|---|---|---|---|---|---|---|
| **Abyssal Lanterns** `abyssal-lanterns` | Translucent bioluminescent drifters — bells, fringed discs, frilly-armed and comb jellies — pulse and travel through the deep night ocean, through three depths of sinking marine snow, under swaying moonlight shafts and a rippling net of surface light, with drifting plankton haze, sparks blooming at the edges and passing waves of plankton light. | Claude Code (claude-opus-5-5) ×5 | 1.61 · 1.77 ms | 90 mW | 12–20 · 15–20 | 66 / 76 % · 48 / 62 %, 9 of 9 regions |
| **Ink and Ember** `ink-and-ember` | A sumi-e mountain range at dusk on dark handmade paper: pines on the crag and ridge crests sway as gusts travel through them, mist veils drift and breathe at their own depths, dry-brush cloud wisps form and dissolve, a slow river shimmers with the seal-red sun's broken reflection, a lantern boat sheds embers and a small flock passes now and then. | Codex (openai.gpt-5.6-luna) ×2, Codex (openai.gpt-5.6-sol) ×2, Claude Code (claude-opus-5-5) ×3 | 0.82 · 0.74 ms | 69 mW | 45–48 · 29–34 | 69 / 67 % · 37 / 34 %, 9 of 9 |
| **Liquid Glass** `liquid-glass` | Deep midnight, violet and teal colour fields flowing behind a thick pane of curved glass, with dark wisps folding through the top band, an undulating ember ribbon trailed by warm motes, glints sliding along the glass edges and morphing pool caustics (WebGL). | Kiro CLI (claude-opus-5.5) ×2, Claude Code (claude-opus-5-5) ×2 | 1.79 · 2.36 ms | 30 mW¹ | 42–52 · 6–20 | 86 / 82 % · 50 / 49 %, 9 of 9 |
| **Rain on the River** `rain-on-the-river` | A night skyline of original towers in soft rain across a wide river: mist drifting through the towers, windows changing, slow rooftop lights and a sweeping beacon, traffic on the lit cable-stayed bridge and the far shore, and a lit barge trailing a fading wake through long, wavering reflections. | Claude Code (claude-opus-5-5), Kiro CLI (claude-opus-5.5), Claude Code, Codex (openai.gpt-6.1-sol) ×2 | 2.78 · 3.42 ms | 64 mW | 22–24 · 9–16 | 100 / 100 % · 100 / 100 %², 9 of 9 |
| **Ringed Giant** `ringed-giant` | A banded gas giant turning once every five minutes, its zonal winds shearing the bands and carrying storms into the night side, the whole ringed system nodding gently under a distant star; glints orbit the rings, three moons pass in front of and behind rings and globe, and parallax stars, fine dust, far nebula filaments and the odd faint meteor keep deep space alive. | Codex (openai.gpt-5.6-luna) ×2, Codex (openai.gpt-5.6-sol), Claude Code (claude-opus-5-5) ×3, Codex (openai.gpt-6.1-sol) | 1.32 · 1.67 ms | 56 mW³ | 21–24 · 3–5 | 100 / 99 % · 99 / 98 %, 9 of 9 |

Budgets: ≤ 4 ms at 1512×982@2, ≤ 6 ms at 5120×1440@1, ≤ 300 mW (aim < 150), mean brightness ≤ 165
and ≤ 120 behind the clock (0–255); motion within 5 s over ≥ 25 % of the frame and in ≥ 5 of its 9
regions (aim ≥ 50 % within 5 s, ≥ 25 % within 2 s, all 9), not busy (≤ 50 % changing strongly within
0.5 s) and no flicker (≤ 30 %); all five measure 0 % busy and 0–1 % flicker. ¹ WebGL work runs on the
GPU, which the CPU-energy figure doesn't include. ² The falling rain alone changes every tile; the
city underneath (mist, windows, lights, bridge traffic, the barge) was brought to life in the
November 2026 rounds by comparing stills a few seconds apart. ³ The planet's surface is remapped in
JavaScript at 8 Hz and cross-faded every frame; at full quality on power (60 fps, scale 1) it draws
about 170–200 mW, the most of the five (the others: 70–185 mW).

### The motion pass (November 2026)

Users found the first versions beautiful but too still, and `livepaper check` gained a motion
measure (SCENE_API.md §7). Each scene then got `livepaper ai modify` rounds with a "make it gently
alive everywhere" brief — Claude Code for most, Codex (gpt-6.1-sol, `model_reasoning_effort =
"xhigh"`) for Rain on the River and Ringed Giant's energy pass — reviewed like the originals:

| Scene | Before: within 5 s (16:9 / 5:4), regions | After |
|---|---|---|
| Ringed Giant | 7 / 9 %, 2 / 1 of 9 (fails) | 100 / 99 %, 9 / 9 |
| Ink and Ember | 2 / 2 %, 0 / 0 of 9 (fails) | 69 / 67 %, 9 / 9 |
| Abyssal Lanterns | 30 / 40 %, 6 / 6 of 9 | 66 / 76 %, 9 / 9 (and battery energy from ~135–155 to ~60–90 mW) |
| Liquid Glass | 47 / 45 %, 7 / 7 of 9 | 86 / 82 %, 9 / 9 |
| Rain on the River | 100 / 100 %, 9 / 9 (rain only) | 100 / 100 %, 9 / 9 (city alive too) |

## Adding or updating a built-in scene

1. Author it in a scratch library: `LIVEPAPER_HOME=$(mktemp -d) livepaper ai create "…" --harness …`
   (or copy `Scenes/<id>.lpscene` into `$LIVEPAPER_HOME/Library/` to work on a built-in as your own
   scene) and refine with `livepaper ai modify <id> "…"` until the stills in `.check/` are excellent
   at 32:9, 16:10, 5:4, thumbnail size and t = 600, and the `motion` line shows the whole frame gently
   alive (look at `.check/previews/motion-*.jpg`; stills a few seconds apart show *what* moves).
2. On the library copy: `livepaper check <pkg> --power` (records `performance` in `scene.json`) and
   `livepaper thumbnail <pkg> [--t <moment>]` (the app renders thumbnails only for the user's own
   scenes, so built-ins ship `thumbnail.jpg`). The energy reading is noisy while other work runs on
   the Mac: repeat `livepaper live <pkg>` two or three times and trust the median.
3. Copy `scene.json`, `scene.js`, `thumbnail.jpg`, `history.jsonl` (and `assets/`, if any) into
   `Scenes/<id>.lpscene/` — not `.check/` or `history/` — and list it here.
4. `swift run LivePaperSelfTest scenes.` checks the packages: manifest, compile, recorded budgets,
   thumbnail, provenance, no machine-specific paths, and that this page lists every scene.
   `LIVEPAPER_SELFTEST_E2E=1 swift run LivePaperSelfTest runtime.e2e.motionBuiltins` prints their
   motion numbers again (it uses or starts one render server).
