// EVILBOTNET — a botnet swarm-command game.
// You are the botmaster. Lead a flocking swarm of bots across a network,
// infect nodes by swarming them, and take over the whole graph before the
// EDR "sentinels" delete your swarm or re-clean your nodes.
//
// Zig -> wasm32-freestanding. Pure software framebuffer (no WebGL).

const W: usize = 360;
const H: usize = 600;

var framebuffer: [W * H]u32 = undefined;

// ---------------- tunables ----------------
const MAX_BOTS: usize = 400;
const START_BOTS: usize = 50;

const NODE_COUNT: usize = 8;
const NODE_INF_R: f32 = 30; // infection radius around a node
const NODE_DRAW_R: f32 = 13;

const MAX_SENT: usize = 8;
const START_SENT: usize = 2;
const SENT_SPEED: f32 = 97; // a hair faster than bots: you can't just outrun them
const SENT_KILL_R: f32 = 18;
const SENT_SCARE_R: f32 = 40; // bots react to sentinels later -> more deaths
const SENT_KILL_CD: f32 = 0.06; // seconds between kill-bursts per sentinel
const SENT_KILL_N: usize = 3; // bots deleted per burst in range

const BOT_SPEED: f32 = 96;
const BOT_FORCE: f32 = 520;
const SEP_R: f32 = 11;
const VIEW_R: f32 = 30;
const W_SEP: f32 = 1.7;
const W_ALIGN: f32 = 0.85;
const W_COH: f32 = 0.8;
const W_SEEK: f32 = 1.1;
const W_FLEE: f32 = 1.15;

const INF_CAP: f32 = 18; // bots beyond this don't speed infection further
const INF_GAIN: f32 = 0.95; // per second at full cap
const INF_DECAY: f32 = 0.02; // slow self-heal when no bots present
const INF_DISINFECT: f32 = 0.14; // sentinel scrubbing rate
const OWN_LOSE_AT: f32 = 0.6; // hysteresis: lose a captured node only below this

const OWN_BONUS_BOTS: usize = 18;
const OWN_SPAWN_DT: f32 = 3.4;
const OWN_SPAWN_N: usize = 3;

const SURGE_DUR: f32 = 1.0;
const SURGE_CD: f32 = 4.5;

const COLLAPSE_N: usize = 6; // held below this many bots...
const COLLAPSE_T: f32 = 4.0; // ...for this long = botnet dismantled (loss)

const MAX_PART: usize = 400;
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

var node_x: [NODE_COUNT]f32 = undefined;
var node_y: [NODE_COUNT]f32 = undefined;
var node_inf: [NODE_COUNT]f32 = undefined;
var node_owned: [NODE_COUNT]bool = undefined;
var node_spawn_t: [NODE_COUNT]f32 = undefined;
var node_pulse: [NODE_COUNT]f32 = undefined;

var link_a: [MAX_LINKS]usize = undefined;
var link_b: [MAX_LINKS]usize = undefined;
var link_count: usize = 0;

var sent_x: [MAX_SENT]f32 = undefined;
var sent_y: [MAX_SENT]f32 = undefined;
var sent_vx: [MAX_SENT]f32 = undefined;
var sent_vy: [MAX_SENT]f32 = undefined;
var sent_kcd: [MAX_SENT]f32 = undefined;
var sent_count: usize = 0;
var sent_spawn_t: f32 = 0;

const Particle = struct { x: f32, y: f32, vx: f32, vy: f32, life: f32, max: f32, color: u32 };
var parts: [MAX_PART]Particle = undefined;
var part_count: usize = 0;

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

// ---------------- helpers ----------------
fn addBot(x: f32, y: f32) void {
    if (bot_count >= MAX_BOTS) return;
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
    while (i < NODE_COUNT) : (i += 1) {
        if (node_owned[i]) n += 1;
    }
    return n;
}
// triangle wave 0..1, no trig
fn pulse(t: f32) f32 {
    const f = t - @floor(t);
    return if (f < 0.5) f * 2 else (1 - f) * 2;
}

// ---------------- setup ----------------
fn placeNodes() void {
    node_x[0] = W / 2;
    node_y[0] = H - 110;
    var placed: usize = 1;
    var tries: usize = 0;
    while (placed < NODE_COUNT and tries < 4000) : (tries += 1) {
        const x = rndRange(42, W - 42);
        const y = rndRange(86, H - 150);
        var ok = true;
        var j: usize = 0;
        while (j < placed) : (j += 1) {
            if (dist2(x, y, node_x[j], node_y[j]) < 76 * 76) {
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
    while (placed < NODE_COUNT) : (placed += 1) {
        node_x[placed] = rndRange(42, W - 42);
        node_y[placed] = rndRange(86, H - 150);
    }
    var i: usize = 0;
    while (i < NODE_COUNT) : (i += 1) {
        node_inf[i] = 0;
        node_owned[i] = false;
        node_spawn_t[i] = 0;
        node_pulse[i] = 0;
    }
    node_inf[0] = 1.0;
    node_owned[0] = true;
}

fn addLink(a: usize, b: usize) void {
    if (b >= NODE_COUNT) return;
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
    while (i < NODE_COUNT) : (i += 1) {
        var n1: usize = NODE_COUNT;
        var n2: usize = NODE_COUNT;
        var d1: f32 = 1e30;
        var d2: f32 = 1e30;
        var j: usize = 0;
        while (j < NODE_COUNT) : (j += 1) {
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
    sent_count += 1;
}

export fn init(seed: u32) void {
    rng_state = seed | 1;
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

    placeNodes();
    buildLinks();

    var i: usize = 0;
    while (i < START_BOTS) : (i += 1) {
        addBot(node_x[0] + rndRange(-18, 18), node_y[0] + rndRange(-18, 18));
    }
    target_x = node_x[0];
    target_y = node_y[0];

    i = 0;
    while (i < START_SENT) : (i += 1) spawnSentinel();
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
    const max_spd: f32 = if (surging) BOT_SPEED * 1.95 else BOT_SPEED;
    const view2 = VIEW_R * VIEW_R;
    const sep2 = SEP_R * SEP_R;

    var i: usize = 0;
    while (i < bot_count) : (i += 1) {
        var sepx: f32 = 0;
        var sepy: f32 = 0;
        var alx: f32 = 0;
        var aly: f32 = 0;
        var cohx: f32 = 0;
        var cohy: f32 = 0;
        var n: f32 = 0;

        var j: usize = 0;
        while (j < bot_count) : (j += 1) {
            if (j == i) continue;
            const dx = bot_x[i] - bot_x[j];
            const dy = bot_y[i] - bot_y[j];
            const d2 = dx * dx + dy * dy;
            if (d2 > view2) continue;
            if (d2 < sep2 and d2 > 0.0001) {
                const inv = 1.0 / d2;
                sepx += dx * inv;
                sepy += dy * inv;
            }
            alx += bot_vx[j];
            aly += bot_vy[j];
            cohx += bot_x[j];
            cohy += bot_y[j];
            n += 1;
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

        // soft walls
        if (bot_x[i] < 10) ax += (10 - bot_x[i]) * 30;
        if (bot_x[i] > W - 10) ax += ((W - 10) - bot_x[i]) * 30;
        if (bot_y[i] < 74) ay += (74 - bot_y[i]) * 30;
        if (bot_y[i] > H - 6) ay += ((H - 6) - bot_y[i]) * 30;

        // clamp force
        const fmag = @sqrt(ax * ax + ay * ay);
        if (fmag > BOT_FORCE) {
            const k = BOT_FORCE / fmag;
            ax *= k;
            ay *= k;
        }

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
    }
}

fn stepNodes(dt: f32) void {
    var i: usize = 0;
    while (i < NODE_COUNT) : (i += 1) {
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
            node_inf[i] += k * INF_GAIN * dt;
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
    const desired = START_SENT + (ownedCount() -| 1);
    sent_spawn_t -= dt;
    if (sent_count < desired and sent_count < MAX_SENT and sent_spawn_t <= 0) {
        spawnSentinel();
        sent_spawn_t = 0.9;
    }

    var cx: f32 = 0;
    var cy: f32 = 0;
    centroid(&cx, &cy);

    var s: usize = 0;
    while (s < sent_count) : (s += 1) {
        // head for the nearest node where the swarm is active; else hunt the swarm
        var tx = cx;
        var ty = cy;
        var best: f32 = 1e30;
        var i: usize = 0;
        while (i < NODE_COUNT) : (i += 1) {
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

        var dx = tx - sent_x[s];
        var dy = ty - sent_y[s];
        const d = @sqrt(dx * dx + dy * dy);
        if (d > 0.001) {
            dx /= d;
            dy /= d;
        }
        sent_vx[s] = dx * SENT_SPEED + rndRange(-8, 8);
        sent_vy[s] = dy * SENT_SPEED + rndRange(-8, 8);
        sent_x[s] += sent_vx[s] * dt;
        sent_y[s] += sent_vy[s] * dt;
        sent_x[s] = clampf(sent_x[s], 4, W - 4);
        sent_y[s] = clampf(sent_y[s], 74, H - 4);

        if (sent_kcd[s] > 0) sent_kcd[s] -= dt;
        if (surge_t <= 0 and sent_kcd[s] <= 0) {
            var killed: usize = 0;
            var b: usize = 0;
            while (b < bot_count and killed < SENT_KILL_N) {
                if (dist2(bot_x[b], bot_y[b], sent_x[s], sent_y[s]) < SENT_KILL_R * SENT_KILL_R) {
                    burst(bot_x[b], bot_y[b], 5, 90, COL_SENT);
                    killBot(b);
                    killed += 1;
                } else b += 1;
            }
            if (killed > 0) sent_kcd[s] = SENT_KILL_CD;
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
    while (i < NODE_COUNT) : (i += 1) {
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
        if (bot_count == 0 or collapse_t >= COLLAPSE_T) state = .lost;
        if (allOwned()) state = .won;
    } else {
        stepBots(dt);
    }
    stepParticles(dt);
    render();
}

// ---------------- render ----------------
fn render() void {
    clear(COL_BG);

    var gx: f32 = 0;
    while (gx < W) : (gx += 30) fillRect(gx, 72, 1, H - 72, COL_GRID);
    var gy: f32 = 72;
    while (gy < H) : (gy += 30) fillRect(0, gy, W, 1, COL_GRID);

    var l: usize = 0;
    while (l < link_count) : (l += 1) {
        const a = link_a[l];
        const b = link_b[l];
        const both = node_owned[a] and node_owned[b];
        const c = if (both) scaleColor(COL_OWNED, 0.5) else rgb(20, 40, 34);
        drawLine(node_x[a], node_y[a], node_x[b], node_y[b], c);
    }

    var i: usize = 0;
    while (i < NODE_COUNT) : (i += 1) {
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

    const bc = if (surge_t > 0) COL_BOT_SURGE else COL_BOT;
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
        circleOutline(sx, sy, SENT_KILL_R, scaleColor(COL_SENT, 0.45));
        const pr = SENT_SCARE_R * (0.6 + 0.4 * pulse(anim_t * 3 + @as(f32, @floatFromInt(s))));
        circleOutline(sx, sy, pr, rgb(60, 12, 14));
        fillCircle(sx, sy, 5, COL_SENT);
        fillCircle(sx, sy, 2.5, rgb(255, 220, 220));
    }

    if (state == .playing) {
        circleOutline(target_x, target_y, 6 + 2 * pulse(anim_t * 4), scaleColor(COL_BOT, 0.7));
        plot(@intFromFloat(target_x), @intFromFloat(target_y), COL_BOT);
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
    return @as(i32, NODE_COUNT);
}
export fn getTakeover() i32 {
    return @intCast((ownedCount() * 100) / NODE_COUNT);
}
export fn getSurge() f32 {
    if (surge_cd <= 0) return 1.0;
    return clampf(1.0 - surge_cd / SURGE_CD, 0, 1);
}
export fn getNodeX(i: i32) f32 {
    const u: usize = @intCast(i);
    return if (u < NODE_COUNT) node_x[u] else -1;
}
export fn getNodeY(i: i32) f32 {
    const u: usize = @intCast(i);
    return if (u < NODE_COUNT) node_y[u] else -1;
}
export fn getNodeOwnedI(i: i32) i32 {
    const u: usize = @intCast(i);
    return if (u < NODE_COUNT and node_owned[u]) 1 else 0;
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
                surge_cd = SURGE_CD;
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
