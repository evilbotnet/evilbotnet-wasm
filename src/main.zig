// EVILBOTNET — a botnet swarm-command game.
// You are the botmaster. Lead a flocking swarm of bots across a network,
// infect nodes by swarming them, and take over the whole graph before the
// EDR "sentinels" delete your swarm or re-clean your nodes.
//
// Zig -> wasm32-freestanding. Pure software framebuffer (no WebGL).

const W: usize = 450;
const H: usize = 780;

var framebuffer: [W * H]u32 = undefined;

// ---------------- tunables ----------------
const MAX_BOTS: usize = 2400;
const START_BOTS: usize = 150;

const MAX_NODES: usize = 14; // array capacity
var node_count: usize = 8; // active nodes this level (set per level)
const NODE_INF_R: f32 = 32; // infection radius around a node
const NODE_DRAW_R: f32 = 13;

const MAX_SENT: usize = 14;
const START_SENT: usize = 2;
const SENT_SPEED: f32 = 92; // slightly slower than bots: you can kite them
const SENT_KILL_R: f32 = 18;
const SENT_SCARE_R: f32 = 48;
const SENT_KILL_CD: f32 = 0.07; // seconds between kill-bursts per sentinel
const SENT_KILL_N: usize = 3; // bots deleted per burst in range

const BOT_SPEED: f32 = 96;
const BOT_FORCE: f32 = 520;
const SEP_R: f32 = 10;
const VIEW_R: f32 = 30;
const W_SEP: f32 = 1.7;
const W_ALIGN: f32 = 0.85;
const W_COH: f32 = 0.8;
const W_SEEK: f32 = 1.1;
const W_FLEE: f32 = 1.5;

// spatial hash grid (cell == VIEW_R) so flocking neighbor lookups are ~O(n)
const GCELL: f32 = 30.0;
const GW: usize = 15; // W / GCELL
const GH: usize = 26; // H / GCELL
const NCELLS: usize = GW * GH;
const GWi: i32 = @intCast(GW);
const GHi: i32 = @intCast(GH);

// maze walls
const MAX_WALLS: usize = 16;
const WALL_MARGIN: f32 = 13; // repulsion onset distance from a wall

// HEAT: rises with takeover; ramps sentinel pressure for a real endgame
var heat: f32 = 0;

const INF_CAP: f32 = 26; // bots beyond this don't speed infection further
const INF_GAIN: f32 = 1.15; // per second at full cap
const INF_DECAY: f32 = 0.02; // slow self-heal when no bots present
const INF_DISINFECT: f32 = 0.13; // sentinel scrubbing rate
const OWN_LOSE_AT: f32 = 0.55; // hysteresis: lose a captured node only below this

const OWN_BONUS_BOTS: usize = 45;
const OWN_SPAWN_DT: f32 = 2.6;
const OWN_SPAWN_N: usize = 5;

const SURGE_DUR: f32 = 1.2;
const SURGE_CD: f32 = 4.0;

// abilities
const EMP_R: f32 = 160; // sentinels within this of the swarm centroid get stunned
const EMP_DUR: f32 = 2.4; // stun seconds
const EMP_CD: f32 = 9.0;
const FORK_N: usize = 180; // bots spawned by a fork
const FORK_CD: f32 = 13.0;
const CLOAK_DUR: f32 = 3.2; // sentinels lose the swarm
const CLOAK_CD: f32 = 11.0;

// background parallax motes
const MOTE_COUNT: usize = 54;

// ---- per-level / per-run config (set by JS before init) ----
var cfg_start_sent: usize = 2;
var cfg_sent_cap: usize = MAX_SENT;
var cfg_walls: i32 = 1; // wall-density level (0 = none)
var cfg_swarm_cap: usize = 1500; // effective bot cap (<= MAX_BOTS)
var cfg_start_bots: usize = 150;
var cfg_infect: f32 = 1.0; // infection-rate multiplier
var cfg_botspeed: f32 = 1.0; // bot-speed multiplier
var cfg_cooldown: f32 = 1.0; // ability-cooldown multiplier
var unlock_emp: bool = false;
var unlock_fork: bool = false;
var unlock_cloak: bool = false;

const COLLAPSE_N: usize = 8; // held below this many bots...
const COLLAPSE_T: f32 = 4.0; // ...for this long = botnet dismantled (loss)

const MAX_PART: usize = 700;
const MAX_LINKS: usize = 24;

// ---------------- RNG ----------------
var rng_state: u32 = 0x1337c0de;
fn rnd() u32 {
    var x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}
fn rndf() f32 {
    return @as(f32, @floatFromInt(rnd() & 0xFFFFFF)) / 16777215.0;
}
fn rndRange(lo: f32, hi: f32) f32 {
    return lo + rndf() * (hi - lo);
}

// ---------------- colors ----------------
inline fn rgb(r: u32, g: u32, b: u32) u32 {
    return 0xFF000000 | (b << 16) | (g << 8) | r;
}
fn scaleColor(c: u32, k: f32) u32 {
    const r = @as(f32, @floatFromInt(c & 0xFF)) * k;
    const g = @as(f32, @floatFromInt((c >> 8) & 0xFF)) * k;
    const b = @as(f32, @floatFromInt((c >> 16) & 0xFF)) * k;
    return rgb(
        @intFromFloat(clampf(r, 0, 255)),
        @intFromFloat(clampf(g, 0, 255)),
        @intFromFloat(clampf(b, 0, 255)),
    );
}

const COL_BG = rgb(6, 10, 9);
const COL_GRID = rgb(14, 30, 22);
const COL_BOT = rgb(60, 255, 130);
const COL_BOT_SURGE = rgb(180, 255, 220);
const COL_CLEAN = rgb(70, 120, 150);
const COL_CONTEST = rgb(255, 190, 70);
const COL_OWNED = rgb(60, 255, 110);
const COL_SENT = rgb(255, 60, 70);
const COL_WALL = rgb(24, 44, 40);
const COL_WALL_EDGE = rgb(46, 92, 78);

// ---------------- math ----------------
inline fn clampf(v: f32, lo: f32, hi: f32) f32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}
inline fn dist2(ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const dx = ax - bx;
    const dy = ay - by;
    return dx * dx + dy * dy;
}
inline fn absI(v: i32) i32 {
    return if (v < 0) -v else v;
}
inline fn clampI(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

// ---------------- draw primitives ----------------
fn clear(c: u32) void {
    @memset(framebuffer[0..], c);
}
fn plot(x: i32, y: i32, c: u32) void {
    if (x < 0 or y < 0 or x >= @as(i32, W) or y >= @as(i32, H)) return;
    framebuffer[@as(usize, @intCast(y)) * W + @as(usize, @intCast(x))] = c;
}
fn fillRect(fx: f32, fy: f32, fw: f32, fh: f32, c: u32) void {
    var x0 = @as(i32, @intFromFloat(@floor(fx)));
    var y0 = @as(i32, @intFromFloat(@floor(fy)));
    var x1 = @as(i32, @intFromFloat(@floor(fx + fw)));
    var y1 = @as(i32, @intFromFloat(@floor(fy + fh)));
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > @as(i32, W)) x1 = @as(i32, W);
    if (y1 > @as(i32, H)) y1 = @as(i32, H);
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = @as(usize, @intCast(y)) * W;
        var x = x0;
        while (x < x1) : (x += 1) framebuffer[row + @as(usize, @intCast(x))] = c;
    }
}
fn fillCircle(cx: f32, cy: f32, r: f32, c: u32) void {
    const r2 = r * r;
    var y = @as(i32, @intFromFloat(@floor(cy - r)));
    const ymax = @as(i32, @intFromFloat(@floor(cy + r)));
    while (y <= ymax) : (y += 1) {
        var x = @as(i32, @intFromFloat(@floor(cx - r)));
        const xmax = @as(i32, @intFromFloat(@floor(cx + r)));
        while (x <= xmax) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            if (dx * dx + dy * dy <= r2) plot(x, y, c);
        }
    }
}
fn circleOutline(cx: f32, cy: f32, rr: f32, c: u32) void {
    if (rr < 1) return;
    var x: i32 = @intFromFloat(rr);
    var y: i32 = 0;
    var err: i32 = 1 - x;
    const icx: i32 = @intFromFloat(cx);
    const icy: i32 = @intFromFloat(cy);
    while (x >= y) {
        plot(icx + x, icy + y, c);
        plot(icx + y, icy + x, c);
        plot(icx - y, icy + x, c);
        plot(icx - x, icy + y, c);
        plot(icx - x, icy - y, c);
        plot(icx - y, icy - x, c);
        plot(icx + y, icy - x, c);
        plot(icx + x, icy - y, c);
        y += 1;
        if (err < 0) {
            err += 2 * y + 1;
        } else {
            x -= 1;
            err += 2 * (y - x) + 1;
        }
    }
}
fn drawLine(x0f: f32, y0f: f32, x1f: f32, y1f: f32, c: u32) void {
    var x0: i32 = @intFromFloat(x0f);
    var y0: i32 = @intFromFloat(y0f);
    const x1: i32 = @intFromFloat(x1f);
    const y1: i32 = @intFromFloat(y1f);
    const dx = absI(x1 - x0);
    const dy = -absI(y1 - y0);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        plot(x0, y0, c);
        if (x0 == x1 and y0 == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}

// ---------------- entities ----------------
var bot_x: [MAX_BOTS]f32 = undefined;
var bot_y: [MAX_BOTS]f32 = undefined;
var bot_vx: [MAX_BOTS]f32 = undefined;
var bot_vy: [MAX_BOTS]f32 = undefined;
var bot_count: usize = 0;

// spatial hash: per-cell singly-linked list of bot indices, rebuilt each frame
var cell_head: [NCELLS]i32 = undefined;
var bot_next: [MAX_BOTS]i32 = undefined;

var node_x: [MAX_NODES]f32 = undefined;
var node_y: [MAX_NODES]f32 = undefined;
var node_inf: [MAX_NODES]f32 = undefined;
var node_owned: [MAX_NODES]bool = undefined;
var node_spawn_t: [MAX_NODES]f32 = undefined;
var node_pulse: [MAX_NODES]f32 = undefined;

var link_a: [MAX_LINKS]usize = undefined;
var link_b: [MAX_LINKS]usize = undefined;
var link_count: usize = 0;

var sent_x: [MAX_SENT]f32 = undefined;
var sent_y: [MAX_SENT]f32 = undefined;
var sent_vx: [MAX_SENT]f32 = undefined;
var sent_vy: [MAX_SENT]f32 = undefined;
var sent_kcd: [MAX_SENT]f32 = undefined;
var sent_stun: [MAX_SENT]f32 = undefined; // EMP freeze remaining
var sent_stuck: [MAX_SENT]f32 = undefined; // time spent wedged on a wall
var sent_count: usize = 0;
var sent_spawn_t: f32 = 0;

const Particle = struct { x: f32, y: f32, vx: f32, vy: f32, life: f32, max: f32, color: u32 };
var parts: [MAX_PART]Particle = undefined;
var part_count: usize = 0;

// maze walls (axis-aligned rects): x0,y0,x1,y1
var wall_x0: [MAX_WALLS]f32 = undefined;
var wall_y0: [MAX_WALLS]f32 = undefined;
var wall_x1: [MAX_WALLS]f32 = undefined;
var wall_y1: [MAX_WALLS]f32 = undefined;
var wall_count: usize = 0;

const State = enum(i32) { ready = 0, playing = 1, won = 2, lost = 3 };
var state: State = .ready;

var target_x: f32 = W / 2;
var target_y: f32 = H - 110;
var key_dx: f32 = 0;
var key_dy: f32 = 0;

var surge_t: f32 = 0;
var surge_cd: f32 = 0;
var surge_ring_t: f32 = -1;
var surge_ring_x: f32 = 0;
var surge_ring_y: f32 = 0;

var anim_t: f32 = 0;
var collapse_t: f32 = 0;

// abilities
var emp_cd: f32 = 0;
var fork_cd: f32 = 0;
var cloak_cd: f32 = 0;
var cloak_t: f32 = 0; // active cloak remaining
var emp_ring_t: f32 = -1;
var emp_ring_x: f32 = 0;
var emp_ring_y: f32 = 0;

// background parallax motes
var mote_x: [MOTE_COUNT]f32 = undefined;
var mote_y: [MOTE_COUNT]f32 = undefined;
var mote_v: [MOTE_COUNT]f32 = undefined;
var mote_b: [MOTE_COUNT]f32 = undefined; // brightness/depth

// screen shake (read by JS)
var shake_mag: f32 = 0;

// ---------------- helpers ----------------
fn addBot(x: f32, y: f32) void {
    if (bot_count >= cfg_swarm_cap or bot_count >= MAX_BOTS) return;
    bot_x[bot_count] = x;
    bot_y[bot_count] = y;
    bot_vx[bot_count] = rndRange(-20, 20);
    bot_vy[bot_count] = rndRange(-20, 20);
    bot_count += 1;
}
fn killBot(i: usize) void {
    bot_count -= 1;
    bot_x[i] = bot_x[bot_count];
    bot_y[i] = bot_y[bot_count];
    bot_vx[i] = bot_vx[bot_count];
    bot_vy[i] = bot_vy[bot_count];
}
fn spawnParticle(x: f32, y: f32, vx: f32, vy: f32, life: f32, c: u32) void {
    if (part_count >= MAX_PART) return;
    parts[part_count] = .{ .x = x, .y = y, .vx = vx, .vy = vy, .life = life, .max = life, .color = c };
    part_count += 1;
}
fn burst(x: f32, y: f32, n: usize, spd: f32, c: u32) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        spawnParticle(x, y, rndRange(-spd, spd), rndRange(-spd, spd), rndRange(0.25, 0.6), c);
    }
}
fn ownedCount() usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        if (node_owned[i]) n += 1;
    }
    return n;
}
fn addShake(m: f32) void {
    if (m > shake_mag) shake_mag = m;
}
// triangle wave 0..1, no trig
fn pulse(t: f32) f32 {
    const f = t - @floor(t);
    return if (f < 0.5) f * 2 else (1 - f) * 2;
}

// ---------------- walls (maze) ----------------
fn pushWall(x0: f32, y0: f32, x1: f32, y1: f32) void {
    if (wall_count >= MAX_WALLS) return;
    wall_x0[wall_count] = x0;
    wall_y0[wall_count] = y0;
    wall_x1[wall_count] = x1;
    wall_y1[wall_count] = y1;
    wall_count += 1;
}

fn buildWalls() void {
    wall_count = 0;
    if (cfg_walls <= 0) return; // early levels: open field

    // Coarse room grid; carve dividers with a random opening per line so the
    // field reads as a maze but stays connected and flockable. Density grows
    // with cfg_walls.
    const cols: usize = if (cfg_walls >= 3) 3 else 2;
    const rows: usize = 2 + @as(usize, @intCast(@min(cfg_walls, 2)));
    const ix0: f32 = 34;
    const ix1: f32 = W - 34;
    const iy0: f32 = 118;
    const iy1: f32 = H - 150;
    const cw = (ix1 - ix0) / @as(f32, @floatFromInt(cols));
    const ch = (iy1 - iy0) / @as(f32, @floatFromInt(rows));
    const t: f32 = 5; // half-thickness

    // horizontal dividers (between rows), each missing one column segment
    var r: usize = 1;
    while (r < rows) : (r += 1) {
        const yy = iy0 + ch * @as(f32, @floatFromInt(r));
        const gap = rnd() % cols;
        var c: usize = 0;
        while (c < cols) : (c += 1) {
            if (c == gap) continue;
            const wx0 = ix0 + cw * @as(f32, @floatFromInt(c)) + 8;
            const wx1 = ix0 + cw * @as(f32, @floatFromInt(c + 1)) - 8;
            pushWall(wx0, yy - t, wx1, yy + t);
        }
    }
    // vertical dividers (between cols), each missing one row segment
    var c2: usize = 1;
    while (c2 < cols) : (c2 += 1) {
        const xx = ix0 + cw * @as(f32, @floatFromInt(c2));
        const gap = rnd() % rows;
        var rr: usize = 0;
        while (rr < rows) : (rr += 1) {
            if (rr == gap) continue;
            const wy0 = iy0 + ch * @as(f32, @floatFromInt(rr)) + 8;
            const wy1 = iy0 + ch * @as(f32, @floatFromInt(rr + 1)) - 8;
            pushWall(xx - t, wy0, xx + t, wy1);
        }
    }

    // a couple of block obstacles only at higher densities
    const blocks: usize = if (cfg_walls >= 4) 2 else if (cfg_walls >= 3) 1 else 0;
    var nb: usize = 0;
    while (nb < blocks and wall_count < MAX_WALLS) : (nb += 1) {
        const bw = rndRange(30, 50);
        const bh = rndRange(26, 46);
        const bx = rndRange(ix0 + 12, ix1 - bw - 12);
        const by = rndRange(iy0 + 12, iy1 - bh - 12);
        pushWall(bx, by, bx + bw, by + bh);
    }
}

fn nearAnyWall(x: f32, y: f32, pad: f32) bool {
    var w: usize = 0;
    while (w < wall_count) : (w += 1) {
        if (x > wall_x0[w] - pad and x < wall_x1[w] + pad and
            y > wall_y0[w] - pad and y < wall_y1[w] + pad) return true;
    }
    return false;
}

fn wallForce(x: f32, y: f32, ax: *f32, ay: *f32) void {
    var w: usize = 0;
    while (w < wall_count) : (w += 1) {
        const rx0 = wall_x0[w];
        const ry0 = wall_y0[w];
        const rx1 = wall_x1[w];
        const ry1 = wall_y1[w];
        if (x > rx0 and x < rx1 and y > ry0 and y < ry1) {
            // inside: shove out the nearest face
            const dl = x - rx0;
            const dr = rx1 - x;
            const dtp = y - ry0;
            const db = ry1 - y;
            var nx: f32 = -1;
            var ny: f32 = 0;
            var md = dl;
            if (dr < md) {
                md = dr;
                nx = 1;
                ny = 0;
            }
            if (dtp < md) {
                md = dtp;
                nx = 0;
                ny = -1;
            }
            if (db < md) {
                md = db;
                nx = 0;
                ny = 1;
            }
            ax.* += nx * BOT_FORCE * 2.4;
            ay.* += ny * BOT_FORCE * 2.4;
        } else {
            const cxp = clampf(x, rx0, rx1);
            const cyp = clampf(y, ry0, ry1);
            const dx = x - cxp;
            const dy = y - cyp;
            const d2 = dx * dx + dy * dy;
            if (d2 < WALL_MARGIN * WALL_MARGIN and d2 > 0.0001) {
                const dd = @sqrt(d2);
                const f = 1.0 - dd / WALL_MARGIN;
                ax.* += (dx / dd) * f * BOT_FORCE * 1.7;
                ay.* += (dy / dd) * f * BOT_FORCE * 1.7;
            }
        }
    }
}

fn resolveWalls(x: *f32, y: *f32) void {
    var w: usize = 0;
    while (w < wall_count) : (w += 1) {
        if (x.* > wall_x0[w] and x.* < wall_x1[w] and y.* > wall_y0[w] and y.* < wall_y1[w]) {
            const dl = x.* - wall_x0[w];
            const dr = wall_x1[w] - x.*;
            const dtp = y.* - wall_y0[w];
            const db = wall_y1[w] - y.*;
            var md = dl;
            var ex = wall_x0[w] - 0.5;
            var ey = y.*;
            if (dr < md) {
                md = dr;
                ex = wall_x1[w] + 0.5;
                ey = y.*;
            }
            if (dtp < md) {
                md = dtp;
                ex = x.*;
                ey = wall_y0[w] - 0.5;
            }
            if (db < md) {
                md = db;
                ex = x.*;
                ey = wall_y1[w] + 0.5;
            }
            x.* = ex;
            y.* = ey;
        }
    }
}

// ---------------- setup ----------------
fn placeNodes() void {
    node_x[0] = W / 2;
    node_y[0] = H - 110;
    var placed: usize = 1;
    var tries: usize = 0;
    while (placed < node_count and tries < 6000) : (tries += 1) {
        const x = rndRange(42, W - 42);
        const y = rndRange(96, H - 160);
        if (nearAnyWall(x, y, 22)) continue;
        var ok = true;
        var j: usize = 0;
        while (j < placed) : (j += 1) {
            if (dist2(x, y, node_x[j], node_y[j]) < 70 * 70) {
                ok = false;
                break;
            }
        }
        if (ok) {
            node_x[placed] = x;
            node_y[placed] = y;
            placed += 1;
        }
    }
    while (placed < node_count) : (placed += 1) {
        node_x[placed] = rndRange(42, W - 42);
        node_y[placed] = rndRange(96, H - 160);
    }
    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        node_inf[i] = 0;
        node_owned[i] = false;
        node_spawn_t[i] = 0;
        node_pulse[i] = 0;
    }
    node_inf[0] = 1.0;
    node_owned[0] = true;
}

fn addLink(a: usize, b: usize) void {
    if (b >= node_count) return;
    var k: usize = 0;
    while (k < link_count) : (k += 1) {
        if ((link_a[k] == a and link_b[k] == b) or (link_a[k] == b and link_b[k] == a)) return;
    }
    if (link_count >= MAX_LINKS) return;
    link_a[link_count] = a;
    link_b[link_count] = b;
    link_count += 1;
}
fn buildLinks() void {
    link_count = 0;
    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        var n1: usize = node_count;
        var n2: usize = node_count;
        var d1: f32 = 1e30;
        var d2: f32 = 1e30;
        var j: usize = 0;
        while (j < node_count) : (j += 1) {
            if (j == i) continue;
            const d = dist2(node_x[i], node_y[i], node_x[j], node_y[j]);
            if (d < d1) {
                d2 = d1;
                n2 = n1;
                d1 = d;
                n1 = j;
            } else if (d < d2) {
                d2 = d;
                n2 = j;
            }
        }
        addLink(i, n1);
        addLink(i, n2);
    }
}

fn spawnSentinel() void {
    if (sent_count >= MAX_SENT) return;
    const edge = rnd() % 4;
    var x: f32 = 0;
    var y: f32 = 0;
    switch (edge) {
        0 => {
            x = rndRange(0, W);
            y = 76;
        },
        1 => {
            x = rndRange(0, W);
            y = H - 10;
        },
        2 => {
            x = 6;
            y = rndRange(80, H - 20);
        },
        else => {
            x = W - 6;
            y = rndRange(80, H - 20);
        },
    }
    sent_x[sent_count] = x;
    sent_y[sent_count] = y;
    sent_vx[sent_count] = 0;
    sent_vy[sent_count] = 0;
    sent_kcd[sent_count] = 0;
    sent_stun[sent_count] = 0;
    sent_stuck[sent_count] = 0;
    sent_count += 1;
}

export fn init(seed: u32) void {
    rng_state = seed | 1;
    clear(COL_BG);
    bot_count = 0;
    sent_count = 0;
    part_count = 0;
    surge_t = 0;
    surge_cd = 0;
    surge_ring_t = -1;
    key_dx = 0;
    key_dy = 0;
    anim_t = 0;
    collapse_t = 0;
    heat = 0;

    emp_cd = 0;
    fork_cd = 0;
    cloak_cd = 0;
    cloak_t = 0;
    emp_ring_t = -1;
    shake_mag = 0;

    // background motes (parallax depth)
    var m: usize = 0;
    while (m < MOTE_COUNT) : (m += 1) {
        mote_x[m] = rndRange(0, W);
        mote_y[m] = rndRange(72, H);
        mote_b[m] = rndRange(0.15, 0.6);
        mote_v[m] = 4 + mote_b[m] * 14; // closer (brighter) drifts faster
    }

    buildWalls();
    placeNodes();
    buildLinks();

    var i: usize = 0;
    while (i < cfg_start_bots) : (i += 1) {
        addBot(node_x[0] + rndRange(-18, 18), node_y[0] + rndRange(-18, 18));
    }
    target_x = node_x[0];
    target_y = node_y[0];

    i = 0;
    while (i < cfg_start_sent) : (i += 1) spawnSentinel();
    sent_spawn_t = 0;

    state = .ready;
}

// ---------------- simulation ----------------
fn centroid(cx: *f32, cy: *f32) void {
    if (bot_count == 0) {
        cx.* = W / 2;
        cy.* = H / 2;
        return;
    }
    var sx: f32 = 0;
    var sy: f32 = 0;
    var i: usize = 0;
    while (i < bot_count) : (i += 1) {
        sx += bot_x[i];
        sy += bot_y[i];
    }
    cx.* = sx / @as(f32, @floatFromInt(bot_count));
    cy.* = sy / @as(f32, @floatFromInt(bot_count));
}

fn stepBots(dt: f32) void {
    const surging = surge_t > 0;
    const seek_w: f32 = if (surging) W_SEEK * 2.4 else W_SEEK;
    const base_spd = BOT_SPEED * cfg_botspeed;
    const max_spd: f32 = if (surging) base_spd * 1.95 else base_spd;
    const view2 = VIEW_R * VIEW_R;
    const sep2 = SEP_R * SEP_R;

    // rebuild spatial hash from current positions
    var c: usize = 0;
    while (c < NCELLS) : (c += 1) cell_head[c] = -1;
    var bi: usize = 0;
    while (bi < bot_count) : (bi += 1) {
        const gx = clampI(@intFromFloat(bot_x[bi] / GCELL), 0, GWi - 1);
        const gy = clampI(@intFromFloat(bot_y[bi] / GCELL), 0, GHi - 1);
        const cc: usize = @intCast(gy * GWi + gx);
        bot_next[bi] = cell_head[cc];
        cell_head[cc] = @intCast(bi);
    }

    var i: usize = 0;
    while (i < bot_count) : (i += 1) {
        var sepx: f32 = 0;
        var sepy: f32 = 0;
        var alx: f32 = 0;
        var aly: f32 = 0;
        var cohx: f32 = 0;
        var cohy: f32 = 0;
        var n: f32 = 0;

        // only scan the 3x3 block of cells around this bot
        const cx0 = clampI(@intFromFloat(bot_x[i] / GCELL), 0, GWi - 1);
        const cy0 = clampI(@intFromFloat(bot_y[i] / GCELL), 0, GHi - 1);
        var gy = cy0 - 1;
        while (gy <= cy0 + 1) : (gy += 1) {
            if (gy < 0 or gy >= GHi) continue;
            var gx = cx0 - 1;
            while (gx <= cx0 + 1) : (gx += 1) {
                if (gx < 0 or gx >= GWi) continue;
                var j = cell_head[@intCast(gy * GWi + gx)];
                while (j >= 0) {
                    const ju: usize = @intCast(j);
                    if (ju != i) {
                        const dx = bot_x[i] - bot_x[ju];
                        const dy = bot_y[i] - bot_y[ju];
                        const d2 = dx * dx + dy * dy;
                        if (d2 <= view2) {
                            if (d2 < sep2 and d2 > 0.0001) {
                                const inv = 1.0 / d2;
                                sepx += dx * inv;
                                sepy += dy * inv;
                            }
                            alx += bot_vx[ju];
                            aly += bot_vy[ju];
                            cohx += bot_x[ju];
                            cohy += bot_y[ju];
                            n += 1;
                        }
                    }
                    j = bot_next[ju];
                }
            }
        }

        var ax: f32 = 0;
        var ay: f32 = 0;
        if (n > 0) {
            ax += sepx * W_SEP * 60;
            ay += sepy * W_SEP * 60;
            ax += (alx / n) * W_ALIGN;
            ay += (aly / n) * W_ALIGN;
            ax += ((cohx / n) - bot_x[i]) * W_COH;
            ay += ((cohy / n) - bot_y[i]) * W_COH;
        }

        // seek the rally point
        ax += (target_x - bot_x[i]) * seek_w;
        ay += (target_y - bot_y[i]) * seek_w;

        // flee sentinels
        var s: usize = 0;
        while (s < sent_count) : (s += 1) {
            const dx = bot_x[i] - sent_x[s];
            const dy = bot_y[i] - sent_y[s];
            const d2 = dx * dx + dy * dy;
            if (d2 < SENT_SCARE_R * SENT_SCARE_R and d2 > 0.001) {
                const dd = @sqrt(d2);
                const f = 1.0 - dd / SENT_SCARE_R;
                const inv = 1.0 / dd;
                ax += dx * inv * f * BOT_FORCE * W_FLEE;
                ay += dy * inv * f * BOT_FORCE * W_FLEE;
            }
        }

        // soft walls (field edges)
        if (bot_x[i] < 10) ax += (10 - bot_x[i]) * 30;
        if (bot_x[i] > W - 10) ax += ((W - 10) - bot_x[i]) * 30;
        if (bot_y[i] < 74) ay += (74 - bot_y[i]) * 30;
        if (bot_y[i] > H - 6) ay += ((H - 6) - bot_y[i]) * 30;

        // clamp steering force (before wall force, so walls always win)
        const fmag = @sqrt(ax * ax + ay * ay);
        if (fmag > BOT_FORCE) {
            const k = BOT_FORCE / fmag;
            ax *= k;
            ay *= k;
        }

        // maze walls (added after the clamp; bots must never pass through)
        wallForce(bot_x[i], bot_y[i], &ax, &ay);

        bot_vx[i] += ax * dt;
        bot_vy[i] += ay * dt;
        const sp = @sqrt(bot_vx[i] * bot_vx[i] + bot_vy[i] * bot_vy[i]);
        if (sp > max_spd) {
            const k = max_spd / sp;
            bot_vx[i] *= k;
            bot_vy[i] *= k;
        }
        bot_x[i] += bot_vx[i] * dt;
        bot_y[i] += bot_vy[i] * dt;
        bot_x[i] = clampf(bot_x[i], 3, W - 3);
        bot_y[i] = clampf(bot_y[i], 72, H - 3);
        resolveWalls(&bot_x[i], &bot_y[i]);
    }
}

fn stepNodes(dt: f32) void {
    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        var near: f32 = 0;
        var b: usize = 0;
        while (b < bot_count) : (b += 1) {
            if (dist2(bot_x[b], bot_y[b], node_x[i], node_y[i]) < NODE_INF_R * NODE_INF_R) near += 1;
        }
        var sentHere = false;
        var s: usize = 0;
        while (s < sent_count) : (s += 1) {
            if (dist2(sent_x[s], sent_y[s], node_x[i], node_y[i]) < (NODE_INF_R + 6) * (NODE_INF_R + 6)) {
                sentHere = true;
                break;
            }
        }

        const prev_owned = node_owned[i];
        if (near > 0) {
            const k = clampf(near / INF_CAP, 0, 1);
            node_inf[i] += k * INF_GAIN * cfg_infect * dt;
        } else {
            node_inf[i] -= INF_DECAY * dt;
        }
        if (sentHere and near < INF_CAP * 0.5) node_inf[i] -= INF_DISINFECT * dt;
        node_inf[i] = clampf(node_inf[i], 0, 1);

        // hysteresis: capture at full, only lose ownership once well scrubbed
        if (!node_owned[i] and node_inf[i] >= 0.999) {
            node_owned[i] = true;
        } else if (node_owned[i] and node_inf[i] < OWN_LOSE_AT) {
            node_owned[i] = false;
        }
        if (node_pulse[i] > 0) node_pulse[i] -= dt;

        if (node_owned[i] and !prev_owned) {
            node_pulse[i] = 0.5;
            burst(node_x[i], node_y[i], 26, 170, COL_OWNED);
            addShake(5);
            var k: usize = 0;
            while (k < OWN_BONUS_BOTS) : (k += 1) addBot(node_x[i] + rndRange(-14, 14), node_y[i] + rndRange(-14, 14));
        } else if (!node_owned[i] and prev_owned) {
            burst(node_x[i], node_y[i], 18, 130, COL_SENT);
        }

        if (node_owned[i]) {
            node_spawn_t[i] -= dt;
            if (node_spawn_t[i] <= 0) {
                node_spawn_t[i] = OWN_SPAWN_DT;
                var k: usize = 0;
                while (k < OWN_SPAWN_N) : (k += 1) addBot(node_x[i] + rndRange(-10, 10), node_y[i] + rndRange(-10, 10));
            }
        }
    }
}

fn stepSentinels(dt: f32) void {
    // HEAT rises with takeover; eases toward target so it ramps smoothly.
    const owned = ownedCount();
    const denom: f32 = if (node_count > 0) @floatFromInt(node_count) else 1.0;
    const target_heat = @as(f32, @floatFromInt(owned)) / denom;
    heat += (target_heat - heat) * clampf(dt * 0.8, 0, 1);

    // more sentinels, faster and deadlier, as heat climbs (capped per level)
    const cap = @min(cfg_sent_cap, MAX_SENT);
    const span: usize = if (cap > cfg_start_sent) cap - cfg_start_sent else 0;
    const extra: usize = @intFromFloat(heat * @as(f32, @floatFromInt(span)));
    const desired = @min(cfg_start_sent + (owned -| 1) + extra, cap);
    const spd = SENT_SPEED * (1.0 + heat * 0.35);
    const kill_cd = SENT_KILL_CD * (1.0 - heat * 0.4); // up to 40% faster kills
    const kill_n: usize = SENT_KILL_N + @as(usize, @intFromFloat(heat * 2.0));

    sent_spawn_t -= dt;
    if (sent_count < desired and sent_count < MAX_SENT and sent_spawn_t <= 0) {
        spawnSentinel();
        sent_spawn_t = 0.7;
    }

    var cx: f32 = 0;
    var cy: f32 = 0;
    centroid(&cx, &cy);

    var s: usize = 0;
    while (s < sent_count) : (s += 1) {
        // EMP freeze: skip movement and kills entirely
        if (sent_stun[s] > 0) {
            sent_stun[s] -= dt;
            continue;
        }

        const cloaked = cloak_t > 0;

        // target: nearest active node; else hunt the swarm. While cloaked the
        // EDR can't see the swarm, so it just mills in place.
        var tx = sent_x[s];
        var ty = sent_y[s];
        if (!cloaked) {
            tx = cx;
            ty = cy;
            var best: f32 = 1e30;
            var i: usize = 0;
            while (i < node_count) : (i += 1) {
                const active = (node_inf[i] > 0.12 and node_inf[i] < 1.0) or (node_owned[i] and i != 0);
                if (active) {
                    const d = dist2(sent_x[s], sent_y[s], node_x[i], node_y[i]);
                    if (d < best) {
                        best = d;
                        tx = node_x[i];
                        ty = node_y[i];
                    }
                }
            }
        }

        var dx = tx - sent_x[s];
        var dy = ty - sent_y[s];
        const dlen = @sqrt(dx * dx + dy * dy);
        if (dlen > 0.001) {
            dx /= dlen;
            dy /= dlen;
        }
        var ax = dx * spd;
        var ay = dy * spd;
        // steer around walls
        wallForce(sent_x[s], sent_y[s], &ax, &ay);
        sent_vx[s] = ax + rndRange(-8, 8);
        sent_vy[s] = ay + rndRange(-8, 8);

        const ox = sent_x[s];
        const oy = sent_y[s];
        sent_x[s] += sent_vx[s] * dt;
        sent_y[s] += sent_vy[s] * dt;
        sent_x[s] = clampf(sent_x[s], 4, W - 4);
        sent_y[s] = clampf(sent_y[s], 74, H - 4);
        resolveWalls(&sent_x[s], &sent_y[s]);

        // lure/unstick: a sentinel wedged against a wall snags briefly (a real
        // tactic to shake pursuit) but kicks itself free so it never clogs.
        const moved = dist2(sent_x[s], sent_y[s], ox, oy);
        if (!cloaked and moved < 0.4) {
            sent_stuck[s] += dt;
            if (sent_stuck[s] > 0.7) {
                sent_x[s] = clampf(sent_x[s] + rndRange(-16, 16), 4, W - 4);
                sent_y[s] = clampf(sent_y[s] + rndRange(-16, 16), 74, H - 4);
                resolveWalls(&sent_x[s], &sent_y[s]);
                sent_stuck[s] = 0;
            }
        } else {
            sent_stuck[s] = 0;
        }

        if (sent_kcd[s] > 0) sent_kcd[s] -= dt;
        if (surge_t <= 0 and !cloaked and sent_kcd[s] <= 0) {
            var killed: usize = 0;
            var b: usize = 0;
            while (b < bot_count and killed < kill_n) {
                if (dist2(bot_x[b], bot_y[b], sent_x[s], sent_y[s]) < SENT_KILL_R * SENT_KILL_R) {
                    burst(bot_x[b], bot_y[b], 5, 90, COL_SENT);
                    killBot(b);
                    killed += 1;
                } else b += 1;
            }
            if (killed > 0) sent_kcd[s] = kill_cd;
        }
    }
}

fn stepParticles(dt: f32) void {
    var i: usize = 0;
    while (i < part_count) {
        parts[i].life -= dt;
        if (parts[i].life <= 0) {
            part_count -= 1;
            parts[i] = parts[part_count];
            continue;
        }
        parts[i].vx *= 0.92;
        parts[i].vy *= 0.92;
        parts[i].x += parts[i].vx * dt;
        parts[i].y += parts[i].vy * dt;
        i += 1;
    }
}

fn allOwned() bool {
    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        if (!node_owned[i]) return false;
    }
    return true;
}

export fn update(dt_in: f32) void {
    var dt = dt_in;
    if (dt > 0.05) dt = 0.05;
    anim_t += dt;

    if (key_dx != 0 or key_dy != 0) {
        target_x = clampf(target_x + key_dx * 240 * dt, 0, W);
        target_y = clampf(target_y + key_dy * 240 * dt, 72, H);
    }

    if (surge_t > 0) surge_t -= dt;
    if (surge_cd > 0) surge_cd -= dt;
    if (surge_ring_t >= 0) {
        surge_ring_t += dt;
        if (surge_ring_t > 0.5) surge_ring_t = -1;
    }

    if (emp_cd > 0) emp_cd -= dt;
    if (fork_cd > 0) fork_cd -= dt;
    if (cloak_cd > 0) cloak_cd -= dt;
    if (cloak_t > 0) cloak_t -= dt;
    if (emp_ring_t >= 0) {
        emp_ring_t += dt;
        if (emp_ring_t > 0.55) emp_ring_t = -1;
    }
    if (shake_mag > 0) {
        shake_mag -= dt * 22;
        if (shake_mag < 0) shake_mag = 0;
    }

    // parallax motes drift down slowly and wrap
    var m: usize = 0;
    while (m < MOTE_COUNT) : (m += 1) {
        mote_y[m] += mote_v[m] * dt;
        if (mote_y[m] > H + 4) {
            mote_y[m] = 70;
            mote_x[m] = rndRange(0, W);
        }
    }

    if (state == .ready) {
        stepBots(dt);
    } else if (state == .playing) {
        stepBots(dt);
        stepNodes(dt);
        stepSentinels(dt);
        if (bot_count < COLLAPSE_N) {
            collapse_t += dt;
        } else {
            collapse_t = 0;
        }
        if (bot_count == 0 or collapse_t >= COLLAPSE_T) {
            if (state != .lost) addShake(11);
            state = .lost;
        }
        if (allOwned()) state = .won;
    } else {
        stepBots(dt);
    }
    stepParticles(dt);
    render();
}

// ---------------- render ----------------
// Decay the whole framebuffer toward black each frame -> moving things leave
// short trails. Single shift+mask per pixel (bg is near-black, so this is
// visually identical to fading toward COL_BG but ~3x cheaper).
fn fadeBuffer() void {
    var i: usize = 0;
    while (i < W * H) : (i += 1) {
        const p = framebuffer[i];
        framebuffer[i] = 0xFF000000 | ((p >> 1) & 0x007F7F7F);
    }
}
fn addPx(x: i32, y: i32, r: u32, g: u32, b: u32) void {
    if (x < 0 or y < 0 or x >= @as(i32, W) or y >= @as(i32, H)) return;
    const idx = @as(usize, @intCast(y)) * W + @as(usize, @intCast(x));
    const p = framebuffer[idx];
    var pr = (p & 0xFF) + r;
    if (pr > 255) pr = 255;
    var pg = ((p >> 8) & 0xFF) + g;
    if (pg > 255) pg = 255;
    var pb = ((p >> 16) & 0xFF) + b;
    if (pb > 255) pb = 255;
    framebuffer[idx] = 0xFF000000 | (pb << 16) | (pg << 8) | pr;
}
// soft additive disk (quadratic falloff) -> subtle bloom around bright objects
fn glow(cx: f32, cy: f32, r: f32, cr: u32, cg: u32, cb: u32, intensity: f32) void {
    const r2 = r * r;
    var y = @as(i32, @intFromFloat(@floor(cy - r)));
    const ymax = @as(i32, @intFromFloat(@floor(cy + r)));
    const fcr = @as(f32, @floatFromInt(cr));
    const fcg = @as(f32, @floatFromInt(cg));
    const fcb = @as(f32, @floatFromInt(cb));
    while (y <= ymax) : (y += 1) {
        var x = @as(i32, @intFromFloat(@floor(cx - r)));
        const xmax = @as(i32, @intFromFloat(@floor(cx + r)));
        while (x <= xmax) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const dd = dx * dx + dy * dy;
            if (dd <= r2) {
                const f = 1.0 - dd / r2;
                const k = f * f * intensity;
                addPx(x, y, @intFromFloat(fcr * k), @intFromFloat(fcg * k), @intFromFloat(fcb * k));
            }
        }
    }
}

fn render() void {
    fadeBuffer();

    // parallax motes (background depth)
    var mi: usize = 0;
    while (mi < MOTE_COUNT) : (mi += 1) {
        const c = scaleColor(rgb(40, 120, 80), mote_b[mi] * 0.5);
        plot(@intFromFloat(mote_x[mi]), @intFromFloat(mote_y[mi]), c);
        if (mote_b[mi] > 0.45) {
            plot(@intFromFloat(mote_x[mi] + 1), @intFromFloat(mote_y[mi]), scaleColor(c, 0.5));
        }
    }

    var gx: f32 = 0;
    while (gx < W) : (gx += 30) fillRect(gx, 72, 1, H - 72, COL_GRID);
    var gy: f32 = 72;
    while (gy < H) : (gy += 30) fillRect(0, gy, W, 1, COL_GRID);

    // maze walls
    var wi: usize = 0;
    while (wi < wall_count) : (wi += 1) {
        fillRect(wall_x0[wi], wall_y0[wi], wall_x1[wi] - wall_x0[wi], wall_y1[wi] - wall_y0[wi], COL_WALL);
        fillRect(wall_x0[wi], wall_y0[wi], wall_x1[wi] - wall_x0[wi], 1, COL_WALL_EDGE);
        fillRect(wall_x0[wi], wall_y1[wi] - 1, wall_x1[wi] - wall_x0[wi], 1, COL_WALL_EDGE);
    }

    var l: usize = 0;
    while (l < link_count) : (l += 1) {
        const a = link_a[l];
        const b = link_b[l];
        const both = node_owned[a] and node_owned[b];
        const c = if (both) scaleColor(COL_OWNED, 0.5) else rgb(20, 40, 34);
        drawLine(node_x[a], node_y[a], node_x[b], node_y[b], c);
    }

    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        const inf = node_inf[i];
        var ring = COL_CLEAN;
        if (node_owned[i]) {
            ring = COL_OWNED;
        } else if (inf > 0.05) {
            ring = COL_CONTEST;
        }
        if (node_pulse[i] > 0) {
            const pr = NODE_DRAW_R + (0.5 - node_pulse[i]) * 60;
            circleOutline(node_x[i], node_y[i], pr, scaleColor(COL_OWNED, node_pulse[i] * 2));
        }
        circleOutline(node_x[i], node_y[i], NODE_DRAW_R, ring);
        circleOutline(node_x[i], node_y[i], NODE_DRAW_R - 1, scaleColor(ring, 0.6));
        const core = 2 + inf * (NODE_DRAW_R - 3);
        fillCircle(node_x[i], node_y[i], core, scaleColor(ring, 0.85));
        if (node_owned[i]) {
            const bb = 0.7 + 0.3 * pulse(anim_t * 2 + @as(f32, @floatFromInt(i)));
            fillCircle(node_x[i], node_y[i], 3, scaleColor(COL_OWNED, bb));
        }
    }

    var p: usize = 0;
    while (p < part_count) : (p += 1) {
        const k = parts[p].life / parts[p].max;
        fillRect(parts[p].x - 1, parts[p].y - 1, 2, 2, scaleColor(parts[p].color, k));
    }

    const cloaked = cloak_t > 0;
    const bc = if (surge_t > 0) COL_BOT_SURGE else if (cloaked) rgb(40, 120, 150) else COL_BOT;
    const bdim = scaleColor(bc, 0.5);
    var b: usize = 0;
    while (b < bot_count) : (b += 1) {
        const xi: i32 = @intFromFloat(bot_x[b]);
        const yi: i32 = @intFromFloat(bot_y[b]);
        plot(xi, yi, bc);
        plot(xi + 1, yi, bdim);
        plot(xi - 1, yi, bdim);
        plot(xi, yi + 1, bdim);
        plot(xi, yi - 1, bdim);
    }

    if (surge_ring_t >= 0) {
        const rr = surge_ring_t * 320;
        circleOutline(surge_ring_x, surge_ring_y, rr, scaleColor(COL_BOT_SURGE, 1 - surge_ring_t * 2));
    }

    var s: usize = 0;
    while (s < sent_count) : (s += 1) {
        const sx = sent_x[s];
        const sy = sent_y[s];
        if (sent_stun[s] > 0) {
            // frozen by EMP — icy and inert
            circleOutline(sx, sy, SENT_KILL_R, rgb(80, 150, 200));
            circleOutline(sx, sy, SENT_KILL_R + 3, rgb(40, 90, 130));
            fillCircle(sx, sy, 5, rgb(150, 210, 255));
            fillCircle(sx, sy, 2.5, rgb(240, 250, 255));
        } else {
            circleOutline(sx, sy, SENT_KILL_R, scaleColor(COL_SENT, 0.45));
            const pr = SENT_SCARE_R * (0.6 + 0.4 * pulse(anim_t * 3 + @as(f32, @floatFromInt(s))));
            circleOutline(sx, sy, pr, rgb(60, 12, 14));
            fillCircle(sx, sy, 5, COL_SENT);
            fillCircle(sx, sy, 2.5, rgb(255, 220, 220));
        }
    }

    // EMP shockwave
    if (emp_ring_t >= 0) {
        const er = emp_ring_t * (EMP_R / 0.55);
        circleOutline(emp_ring_x, emp_ring_y, er, scaleColor(rgb(120, 200, 255), 1 - emp_ring_t / 0.55));
        circleOutline(emp_ring_x, emp_ring_y, er * 0.7, scaleColor(rgb(120, 200, 255), (1 - emp_ring_t / 0.55) * 0.6));
    }

    if (state == .playing) {
        circleOutline(target_x, target_y, 6 + 2 * pulse(anim_t * 4), scaleColor(COL_BOT, 0.7));
        plot(@intFromFloat(target_x), @intFromFloat(target_y), COL_BOT);
    }

    // ---- subtle bloom: additive halos on the bright objects ----
    var cx: f32 = 0;
    var cy: f32 = 0;
    centroid(&cx, &cy);
    if (bot_count > 0) {
        const gr = 28.0 + @sqrt(@as(f32, @floatFromInt(bot_count))) * 1.4;
        glow(cx, cy, gr, 8, 36, 18, 0.7);
    }
    i = 0;
    while (i < node_count) : (i += 1) {
        if (node_owned[i]) {
            glow(node_x[i], node_y[i], 24, 14, 60, 26, 0.6);
        } else if (node_inf[i] > 0.05) {
            glow(node_x[i], node_y[i], 18, 60, 44, 12, 0.5);
        }
    }
    s = 0;
    while (s < sent_count) : (s += 1) {
        if (sent_stun[s] > 0) {
            glow(sent_x[s], sent_y[s], 20, 24, 60, 80, 0.6);
        } else {
            glow(sent_x[s], sent_y[s], 20, 70, 14, 16, 0.55);
        }
    }
    if (surge_t > 0) {
        glow(cx, cy, 42, 50, 70, 60, 0.45);
    }
}

// ---------------- exports ----------------
export fn getWidth() i32 {
    return @as(i32, W);
}
export fn getHeight() i32 {
    return @as(i32, H);
}
export fn getFramebuffer() [*]u8 {
    return @ptrCast(&framebuffer);
}
export fn getState() i32 {
    return @intFromEnum(state);
}
export fn getBots() i32 {
    return @intCast(bot_count);
}
export fn getNodesOwned() i32 {
    return @intCast(ownedCount());
}
export fn getNodesTotal() i32 {
    return @intCast(node_count);
}
export fn getTakeover() i32 {
    return @intCast((ownedCount() * 100) / node_count);
}
export fn getSurge() f32 {
    if (surge_cd <= 0) return 1.0;
    return clampf(1.0 - surge_cd / SURGE_CD, 0, 1);
}
export fn getHeat() f32 {
    return clampf(heat, 0, 1);
}
export fn getShake() f32 {
    return shake_mag;
}
fn ready01(cd: f32, max: f32) f32 {
    if (cd <= 0) return 1.0;
    return clampf(1.0 - cd / max, 0, 1);
}
export fn getEmp() f32 {
    return ready01(emp_cd, EMP_CD);
}
export fn getFork() f32 {
    return ready01(fork_cd, FORK_CD);
}
export fn getCloak() f32 {
    return ready01(cloak_cd, CLOAK_CD);
}
export fn abEmp() void {
    if (state != .playing or !unlock_emp or emp_cd > 0) return;
    emp_cd = EMP_CD * cfg_cooldown;
    var cx: f32 = 0;
    var cy: f32 = 0;
    centroid(&cx, &cy);
    emp_ring_x = cx;
    emp_ring_y = cy;
    emp_ring_t = 0;
    addShake(7);
    var s: usize = 0;
    while (s < sent_count) : (s += 1) {
        if (dist2(sent_x[s], sent_y[s], cx, cy) < EMP_R * EMP_R) sent_stun[s] = EMP_DUR;
    }
}
export fn abFork() void {
    if (state != .playing or !unlock_fork or fork_cd > 0) return;
    fork_cd = FORK_CD * cfg_cooldown;
    var cx: f32 = 0;
    var cy: f32 = 0;
    centroid(&cx, &cy);
    addShake(4);
    burst(cx, cy, 30, 150, COL_BOT);
    var k: usize = 0;
    while (k < FORK_N) : (k += 1) addBot(cx + rndRange(-22, 22), cy + rndRange(-22, 22));
}
export fn abCloak() void {
    if (state != .playing or !unlock_cloak or cloak_cd > 0) return;
    cloak_cd = CLOAK_CD * cfg_cooldown;
    cloak_t = CLOAK_DUR;
}

// ---- per-level config setters (JS calls these before init) ----
fn clampUsize(n: i32, lo: usize, hi: usize) usize {
    if (n < 0) return lo;
    var u: usize = @intCast(n);
    if (u < lo) u = lo;
    if (u > hi) u = hi;
    return u;
}
export fn setNodes(n: i32) void {
    node_count = clampUsize(n, 1, MAX_NODES);
}
export fn setStartSent(n: i32) void {
    cfg_start_sent = clampUsize(n, 0, MAX_SENT);
}
export fn setSentCap(n: i32) void {
    cfg_sent_cap = clampUsize(n, 1, MAX_SENT);
}
export fn setWalls(n: i32) void {
    cfg_walls = n;
}
export fn setSwarmCap(n: i32) void {
    cfg_swarm_cap = clampUsize(n, 50, MAX_BOTS);
}
export fn setStartBots(n: i32) void {
    cfg_start_bots = clampUsize(n, 1, MAX_BOTS);
}
export fn setInfect(f: f32) void {
    cfg_infect = clampf(f, 0.2, 4.0);
}
export fn setBotSpeed(f: f32) void {
    cfg_botspeed = clampf(f, 0.5, 3.0);
}
export fn setCooldown(f: f32) void {
    cfg_cooldown = clampf(f, 0.2, 1.5);
}
export fn setUnlock(id: i32, on: i32) void {
    const v = on != 0;
    switch (id) {
        1 => unlock_emp = v,
        2 => unlock_fork = v,
        3 => unlock_cloak = v,
        else => {},
    }
}
export fn getNodeX(i: i32) f32 {
    const u: usize = @intCast(i);
    return if (u < node_count) node_x[u] else -1;
}
export fn getNodeY(i: i32) f32 {
    const u: usize = @intCast(i);
    return if (u < node_count) node_y[u] else -1;
}
export fn getNodeOwnedI(i: i32) i32 {
    const u: usize = @intCast(i);
    return if (u < node_count and node_owned[u]) 1 else 0;
}

export fn pointerMove(nx: f32, ny: f32) void {
    target_x = clampf(nx, 0, 1) * W;
    target_y = clampf(ny, 0, 1) * H;
    if (target_y < 72) target_y = 72;
}
export fn keyDir(dx: f32, dy: f32) void {
    key_dx = dx;
    key_dy = dy;
}
export fn press() void {
    switch (state) {
        .ready => state = .playing,
        .won, .lost => init(rng_state ^ 0x5151a),
        .playing => {
            if (surge_cd <= 0) {
                surge_t = SURGE_DUR;
                surge_cd = SURGE_CD * cfg_cooldown;
                var cx: f32 = 0;
                var cy: f32 = 0;
                centroid(&cx, &cy);
                surge_ring_x = cx;
                surge_ring_y = cy;
                surge_ring_t = 0;
            }
        },
    }
}
