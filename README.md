# EVILBOTNET

A botnet swarm-command game. **~10 KB of WebAssembly**, no engine, no framework —
hand-written [Zig](https://ziglang.org) rendering straight into a software framebuffer,
running up to ~2,400 flocking agents at 60 fps in your browser via a spatial-hash grid.

You are the botmaster. Lead a swarm of bots across a network, smother nodes to
**infect** them, and seize the whole graph before the red EDR **sentinels** delete
your swarm or scrub your nodes back to clean.


## Play

- **Finger / mouse** — lead the rally point; the swarm flocks toward it.
- **SURGE** (Space) — 1.2 s of speed + immunity. Punch a capture through a defended node.
- **EMP** (Q) — freeze nearby sentinels solid for a couple seconds.
- **FORK** (F) — instantly mass a burst of new bots at the swarm.
- **CLOAK** (C) — the EDR loses sight of your swarm; sneak a capture.
- **WASD / arrows** — nudge the rally point (desktop).

Lead sentinels into the maze walls and block obstacles — they snag briefly, which
buys you time (they always free themselves, so it never clogs).

**Roguelite runs:** each level is a network raid. Level 1 starts tiny (3 nodes, one sentinel, open field); clear every node and you **draft one of three upgrades** — bigger swarm, faster spread, overclocked bots, shorter cooldowns, or **unlock a new ability** (EMP / FORK / CLOAK). Then the next level escalates: more nodes, more sentinels, rising **HEAT**, and eventually scattered rock obstacles. Lose your swarm and the run ends — how many levels can you clear? (Best level persists locally.)

Captures are sticky (ownership hysteresis), so you can push outward — but leave a
node undefended too long and a sentinel will grind it back.

## How it works

- `src/main.zig` — the whole game: xorshift RNG, a **spatial-hash grid** for
  ~O(n) flocking (separation / alignment / cohesion + seek + threat-avoidance),
  small circular **rock obstacles** with steering avoidance, node infection with hysteresis, a
  **HEAT** escalation system, EDR sentinel AI, particles, **trails + additive
  bloom**, and a software rasterizer writing `u32` RGBA pixels.
- Target is `wasm32-freestanding` — **no libc, no allocator.** Fixed global
  arrays, builtin math only (`@sqrt`, `@floor`, no libm trig), so the module is
  tiny and never traps.
- `web/index.html` instantiates the wasm, copies the framebuffer into a
  `<canvas>` each frame, and feeds input back through exported functions.

## Build

Requires Zig **0.16.0**.

```sh
zig build           # outputs zig-out/bin/{game.wasm,index.html}
```

Serve `zig-out/bin` with any static server (wasm needs HTTP, not `file://`):

```sh
cd zig-out/bin && python3 -m http.server 8000
# open http://localhost:8000
```

## Deploy

Pushing to `main` triggers `.github/workflows/deploy.yml`, which builds with Zig
0.16.0 and publishes `zig-out/bin` to GitHub Pages. Enable Pages → Source:
**GitHub Actions** in repo settings once.

## License

MIT — do what you want.
