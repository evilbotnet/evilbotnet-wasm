const fs = require("fs");

(async () => {
  const bytes = fs.readFileSync("zig-out/bin/game.wasm");
  const { instance } = await WebAssembly.instantiate(bytes, {});
  const w = instance.exports;
  const W = w.getWidth(), H = w.getHeight();

  // required exports present?
  for (const fn of ["init","update","getFramebuffer","getState","getBots",
      "getNodesOwned","getNodesTotal","getTakeover","getSurge","pointerMove",
      "press","keyDir","getNodeX","getNodeY","getNodeOwnedI","memory"]) {
    if (!(fn in w)) throw new Error("missing export: " + fn);
  }

  function nodes() {
    const n = w.getNodesTotal(), a = [];
    for (let i = 0; i < n; i++) a.push({ i, x: w.getNodeX(i), y: w.getNodeY(i), owned: !!w.getNodeOwnedI(i) });
    return a;
  }

  function playOnce(seed) {
    w.init(seed);
    if (w.getState() !== 0) throw new Error("expected READY");
    w.press();
    if (w.getState() !== 1) throw new Error("expected PLAYING");

    const fb = new Uint32Array(w.memory.buffer, w.getFramebuffer(), W * H);
    let frames = 0, sawNaN = false, surges = 0, lowBots = 999;
    const maxFrames = 60 * 240; // 4 min cap
    let focusX = W/2, focusY = H - 110;

    while (w.getState() === 1 && frames < maxFrames) {
      const ns = nodes().filter(n => !n.owned);
      if (ns.length) {
        // nearest unowned node to our current focus -> sweep, holding until it flips
        let best = ns[0], bd = 1e9;
        for (const n of ns) {
          const d = (n.x - focusX)**2 + (n.y - focusY)**2;
          if (d < bd) { bd = d; best = n; }
        }
        focusX = best.x; focusY = best.y;
        w.pointerMove(best.x / W, best.y / H);
        if (w.getSurge() >= 1 && (frames % 90) === 0) { w.press(); surges++; }
      }
      w.update(1/60);
      frames++;
      const b = w.getBots();
      if (b < lowBots) lowBots = b;
      if (!Number.isFinite(w.getTakeover())) sawNaN = true;
    }

    // sanity: framebuffer non-empty
    let nz = 0; for (let i = 0; i < fb.length; i += 7) if ((fb[i] & 0xffffff) !== 0x090a06 && (fb[i] & 0xffffff) !== 0x0a0a06) nz++;

    return { state: w.getState(), frames, secs: (frames/60).toFixed(1),
             owned: w.getNodesOwned(), total: w.getNodesTotal(),
             bots: w.getBots(), lowBots, surges, sawNaN };
  }

  let wins = 0, losses = 0, timeouts = 0;
  const secs = [];
  for (let s = 1; s <= 5; s++) {
    const r = playOnce(s * 7919 + 1);
    console.log(`seed#${s}: state=${["READY","PLAY","WON","LOST"][r.state]} ` +
      `time=${r.secs}s owned=${r.owned}/${r.total} bots=${r.bots} lowBots=${r.lowBots} surges=${r.surges} NaN=${r.sawNaN}`);
    if (r.sawNaN) throw new Error("NaN detected");
    if (r.state === 2) { wins++; secs.push(parseFloat(r.secs)); }
    else if (r.state === 3) losses++;
    else timeouts++;
  }

  console.log(`\nwins=${wins} losses=${losses} timeouts=${timeouts}`);
  if (wins > 0) {
    const avg = (secs.reduce((a,b)=>a+b,0)/secs.length).toFixed(1);
    console.log(`avg win time: ${avg}s`);
  }
  console.log("ALL CHECKS PASSED (no crash, no NaN, exports intact)");
})().catch(e => { console.error("TEST FAILED:", e); process.exit(1); });
