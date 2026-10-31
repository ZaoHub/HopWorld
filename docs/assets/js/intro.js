(() => {
  const intro = document.getElementById("intro");
  const canvas = intro && intro.querySelector("[data-intro-canvas]");
  const caption = intro && intro.querySelector("[data-intro-caption]");
  const skipBtn = intro && intro.querySelector("[data-intro-skip]");
  const SEEN_KEY = "hopworld-intro-seen";
  let finished = false;

  const finish = () => {
    if (finished) return;
    finished = true;
    try {
      sessionStorage.setItem(SEEN_KEY, "1");
    } catch (_) {
      /* storage unavailable */
    }
    document.body.classList.remove("is-intro");
    document.dispatchEvent(new Event("hopworld:introdone"));
    if (!intro) return;
    intro.classList.add("is-done");
    intro.setAttribute("aria-hidden", "true");
    window.setTimeout(() => intro.remove(), 900);
  };

  const mode = new URLSearchParams(location.search).get("intro");
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  let seen = false;
  try {
    seen = sessionStorage.getItem(SEEN_KEY) === "1";
  } catch (_) {
    /* storage unavailable */
  }
  const ctx = canvas && canvas.getContext("2d");
  if (!ctx || mode === "0" || (mode !== "1" && (reduce || seen))) {
    finish();
    return;
  }

  // Rough continent outlines as [lon, lat]; only used to rasterize a dot map.
  const LAND = [
    [[-168, 66], [-140, 70], [-110, 72], [-85, 70], [-75, 62], [-60, 55], [-55, 48], [-66, 44], [-75, 35], [-81, 25], [-90, 29], [-97, 26], [-97, 20], [-88, 21], [-88, 15], [-80, 8], [-84, 10], [-92, 15], [-105, 20], [-112, 30], [-118, 34], [-124, 40], [-124, 48], [-135, 58], [-150, 60], [-165, 60]],
    [[-50, 60], [-42, 60], [-20, 70], [-20, 80], [-60, 82], [-70, 76], [-55, 68]],
    [[-24, 64], [-14, 64], [-14, 66], [-22, 66]],
    [[-80, 8], [-77, 8], [-60, 10], [-50, 0], [-35, -6], [-40, -22], [-48, -28], [-58, -38], [-65, -55], [-72, -50], [-72, -30], [-70, -18], [-81, -5]],
    [[-10, 36], [-9, 43], [-2, 44], [-5, 48], [2, 51], [8, 54], [10, 58], [5, 62], [15, 69], [28, 71], [40, 68], [40, 55], [30, 46], [28, 41], [22, 37], [15, 38], [12, 44], [5, 43], [-2, 36]],
    [[-5, 50], [1, 51], [-2, 56], [-5, 58], [-6, 55]],
    [[-17, 21], [-10, 30], [-5, 36], [10, 37], [20, 32], [32, 31], [35, 28], [43, 12], [51, 12], [40, -15], [35, -25], [20, -35], [12, -18], [9, 0], [-8, 5], [-17, 14]],
    [[44, -25], [50, -15], [49, -12], [44, -17]],
    [[35, 30], [39, 22], [43, 13], [45, 13], [52, 16], [57, 19], [59, 22], [56, 26], [51, 25], [48, 29], [44, 31], [38, 33]],
    [[28, 41], [35, 36], [45, 40], [50, 30], [57, 25], [60, 22], [67, 25], [73, 20], [78, 8], [80, 13], [85, 20], [92, 22], [98, 15], [100, 3], [104, 1], [108, 12], [110, 20], [120, 25], [122, 31], [120, 40], [128, 35], [130, 43], [140, 48], [143, 55], [160, 60], [180, 66], [180, 70], [140, 73], [100, 78], [70, 73], [60, 68], [40, 68], [40, 55], [30, 46]],
    [[130, 31], [136, 34], [141, 36], [142, 43], [145, 44], [140, 40], [135, 35]],
    [[95, 5], [105, -6], [115, -8], [125, -8], [140, -3], [150, -6], [141, -9], [130, -3], [118, 1], [110, -2], [100, -1]],
    [[114, -22], [122, -18], [131, -12], [137, -12], [142, -11], [146, -19], [153, -26], [150, -37], [140, -38], [132, -32], [115, -34]],
  ];

  const ROUTE = [
    { country: "中国", city: "上海", lon: 121.5, lat: 31.2, ms: 12 },
    { country: "日本", city: "东京", lon: 139.7, lat: 35.7, ms: 46 },
    { country: "美国", city: "洛杉矶", lon: -118.2, lat: 34.1, ms: 152 },
    { country: "巴西", city: "圣保罗", lon: -46.6, lat: -23.5, ms: 238 },
    { country: "英国", city: "伦敦", lon: -0.1, lat: 51.5, ms: 186 },
    { country: "德国", city: "法兰克福", lon: 8.7, lat: 50.1, ms: 172 },
    { country: "新加坡", city: "新加坡", lon: 103.8, lat: 1.35, ms: 64 },
  ];

  const LON0 = -135;
  const LON1 = 165;
  const LAT0 = -50;
  const LAT1 = 75;
  const GLYPH_FONT = '"PingFang SC", "Hiragino Sans GB", "Noto Sans SC", "Source Han Sans SC", "Microsoft YaHei", sans-serif';
  const TAU = Math.PI * 2;

  const HOPS = ROUTE.length - 1;
  const T = { intro: 650, hop: 470, travel: 0.8, pause: 220, form: 1500, hold: 950 };
  const tHopsEnd = T.intro + HOPS * T.hop;
  const tForm = tHopsEnd + T.pause;
  const tHold = tForm + T.form;
  const tEnd = tHold + T.hold;
  const MAX_LAG = 230;

  const rand = (a, b) => a + Math.random() * (b - a);
  const clamp01 = (v) => Math.min(1, Math.max(0, v));
  const easeInOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);
  const easeOut = (t) => 1 - (1 - t) ** 3;
  const quad = (a, b, c, t) => {
    const u = 1 - t;
    return u * u * a + 2 * u * t * b + t * t * c;
  };

  let W = 0;
  let H = 0;
  let dpr = 1;
  let map = { x: 0, y: 0, w: 0, h: 0 };
  let mapLayer = null;
  let nodes = [];
  let arcs = [];
  let glyph = { fs: 0, cx: 0, cy: 0, pts: [] };
  let particles = [];
  let formCaptured = false;
  let lastCaption = "";
  let startedAt = 0;
  let raf = 0;

  const project = (lon, lat) => ({
    x: map.x + ((lon - LON0) / (LON1 - LON0)) * map.w,
    y: map.y + ((LAT1 - lat) / (LAT1 - LAT0)) * map.h,
  });

  const renderMap = () => {
    const mask = document.createElement("canvas");
    mask.width = Math.max(1, Math.ceil(W));
    mask.height = Math.max(1, Math.ceil(H));
    const m = mask.getContext("2d", { willReadFrequently: true });
    m.fillStyle = "#fff";
    LAND.forEach((poly) => {
      m.beginPath();
      poly.forEach(([lon, lat], i) => {
        const p = project(lon, lat);
        if (i) m.lineTo(p.x, p.y);
        else m.moveTo(p.x, p.y);
      });
      m.closePath();
      m.fill();
    });
    const data = m.getImageData(0, 0, mask.width, mask.height).data;

    mapLayer = document.createElement("canvas");
    mapLayer.width = canvas.width;
    mapLayer.height = canvas.height;
    const l = mapLayer.getContext("2d");
    l.setTransform(dpr, 0, 0, dpr, 0, 0);
    const s = Math.max(3.6, Math.min(8.5, map.w / 120));
    const r = s * 0.2;
    l.beginPath();
    for (let y = map.y + s / 2; y < map.y + map.h; y += s) {
      for (let x = map.x + s / 2; x < map.x + map.w; x += s) {
        const ix = Math.round(x);
        const iy = Math.round(y);
        if (ix < 0 || iy < 0 || ix >= mask.width || iy >= mask.height) continue;
        if (data[(iy * mask.width + ix) * 4 + 3] > 0) {
          l.moveTo(x + r, y);
          l.arc(x, y, r, 0, TAU);
        }
      }
    }
    l.fillStyle = "rgba(199, 212, 227, 0.3)";
    l.fill();
  };

  const buildArcs = () => {
    arcs = [];
    for (let i = 0; i < HOPS; i += 1) {
      const a = nodes[i];
      const b = nodes[i + 1];
      const dx = b.x - a.x;
      const dy = b.y - a.y;
      const d = Math.hypot(dx, dy) || 1;
      let px = -dy / d;
      let py = dx / d;
      if (py > 0) {
        px = -px;
        py = -py;
      }
      const lift = Math.min(d * 0.42, H * 0.26);
      arcs.push({ a, b, cx: (a.x + b.x) / 2 + px * lift, cy: (a.y + b.y) / 2 + py * lift });
    }
  };

  const sampleGlyph = () => {
    const fs = Math.round(Math.min(W * 0.3, H * 0.24, 220));
    const cx = W / 2;
    const cy = H * 0.44;
    const x0 = Math.max(0, Math.floor(cx - fs * 1.3));
    const y0 = Math.max(0, Math.floor(cy - fs * 0.8));
    const bw = Math.max(1, Math.min(Math.ceil(W), Math.ceil(cx + fs * 1.3)) - x0);
    const bh = Math.max(1, Math.min(Math.ceil(H), Math.ceil(cy + fs * 0.8)) - y0);
    const off = document.createElement("canvas");
    off.width = Math.max(1, Math.ceil(W));
    off.height = Math.max(1, Math.ceil(H));
    const o = off.getContext("2d", { willReadFrequently: true });
    o.fillStyle = "#fff";
    o.textAlign = "center";
    o.textBaseline = "middle";
    o.font = `800 ${fs}px ${GLYPH_FONT}`;
    o.fillText("跃界", cx, cy);
    const data = o.getImageData(x0, y0, bw, bh).data;
    const step = Math.max(2, Math.round(fs / 42));
    const pts = [];
    for (let y = 0; y < bh; y += step) {
      for (let x = 0; x < bw; x += step) {
        if (data[(y * bw + x) * 4 + 3] > 128) pts.push({ x: x0 + x, y: y0 + y });
      }
    }
    for (let i = pts.length - 1; i > 0; i -= 1) {
      const j = Math.floor(Math.random() * (i + 1));
      [pts[i], pts[j]] = [pts[j], pts[i]];
    }
    return { fs, cx, cy, pts };
  };

  const assignTargets = () => {
    const { pts, cx, cy, fs } = glyph;
    particles.forEach((p, i) => {
      if (pts.length) {
        const t = pts[i % pts.length];
        p.tx = t.x;
        p.ty = t.y;
      } else {
        p.tx = cx + rand(-fs, fs);
        p.ty = cy + rand(-fs * 0.4, fs * 0.4);
      }
    });
  };

  const layout = () => {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = window.innerWidth;
    H = window.innerHeight;
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const ratio = (LON1 - LON0) / (LAT1 - LAT0);
    const mw = Math.min(W * 0.96, H * 0.72 * ratio);
    map = { w: mw, h: mw / ratio, x: (W - mw) / 2, y: H * 0.44 - mw / ratio / 2 };
    nodes = ROUTE.map((r) => ({ ...r, ...project(r.lon, r.lat) }));
    buildArcs();
    renderMap();
    glyph = sampleGlyph();
    if (particles.length) assignTargets();
  };

  const routeS = (t) => {
    if (t <= T.intro) return 0;
    const k = (t - T.intro) / T.hop;
    if (k >= HOPS) return HOPS;
    const i = Math.floor(k);
    return i + easeInOut(clamp01((k - i) / T.travel));
  };

  const arcPoint = (arc, f) => ({
    x: quad(arc.a.x, arc.cx, arc.b.x, f),
    y: quad(arc.a.y, arc.cy, arc.b.y, f),
  });

  const routePoint = (s) => {
    const i = Math.min(HOPS - 1, Math.floor(s));
    return arcPoint(arcs[i], s - i);
  };

  const arrivalAt = (k) => (k === 0 ? T.intro * 0.45 : T.intro + (k - 1) * T.hop + T.travel * T.hop);

  const makeParticles = () => {
    const cap = W * H < 600000 ? 650 : 1000;
    const count = glyph.pts.length ? Math.min(cap, glyph.pts.length) : 500;
    particles = Array.from({ length: count }, () => {
      const lag = Math.random() ** 1.7 * MAX_LAG;
      return {
        lag,
        ang: rand(0, TAU),
        rad: Math.sqrt(Math.random()),
        spin: rand(-0.004, 0.004),
        size: rand(0.8, 1.9),
        hue: lag < 30 ? 0 : Math.random() < 0.6 ? 1 : 2,
        tw: rand(0, TAU),
        ix: rand(0, W),
        iy: rand(0, H),
        delay: rand(0, 420),
        x: 0,
        y: 0,
        px: 0,
        py: 0,
        sx: 0,
        sy: 0,
        cx: 0,
        cy: 0,
        tx: 0,
        ty: 0,
      };
    });
    assignTargets();
    particles.forEach((p) => {
      p.x = p.px = p.ix;
      p.y = p.py = p.iy;
    });
  };

  const setCaption = (text) => {
    if (caption && text !== lastCaption) {
      caption.textContent = text;
      lastCaption = text;
    }
  };

  const updateParticles = (t) => {
    const intoIntro = easeOut(clamp01(t / T.intro));
    if (t >= tForm && !formCaptured) {
      formCaptured = true;
      const origin = nodes[nodes.length - 1];
      particles.forEach((p) => {
        p.sx = p.x;
        p.sy = p.y;
        const dx = p.x - origin.x;
        const dy = p.y - origin.y;
        const d = Math.hypot(dx, dy) || 1;
        const burst = rand(50, 170);
        p.cx = p.x + (dx / d) * burst + rand(-60, 60);
        p.cy = p.y + (dy / d) * burst + rand(-60, 60);
      });
    }

    particles.forEach((p) => {
      p.px = p.x;
      p.py = p.y;
      if (t < tForm) {
        const s = routeS(t - p.lag);
        const base = routePoint(s);
        const f = s >= HOPS ? 0 : s - Math.floor(s);
        const flight = Math.sin(Math.PI * f);
        const spread = 4 + flight * 12 + (p.lag / MAX_LAG) * 7;
        const a = p.ang + t * p.spin;
        const sx = base.x + Math.cos(a) * p.rad * spread;
        const sy = base.y + Math.sin(a) * p.rad * spread;
        p.x = p.ix + (sx - p.ix) * intoIntro;
        p.y = p.iy + (sy - p.iy) * intoIntro;
        p.scale = 1 + flight * 0.7;
      } else if (t < tHold) {
        const local = easeInOut(clamp01((t - tForm - p.delay) / (T.form - 420)));
        p.x = quad(p.sx, p.cx, p.tx, local);
        p.y = quad(p.sy, p.cy, p.ty, local);
        p.scale = 1 + Math.sin(Math.PI * local) * 0.5;
      } else {
        p.x = p.tx + Math.sin(t * 0.004 + p.tw) * 0.5;
        p.y = p.ty + Math.cos(t * 0.004 + p.tw) * 0.5;
        p.scale = 1;
      }
    });
  };

  const drawMapAndRoutes = (t, s) => {
    const formP = t >= tForm ? easeOut(clamp01((t - tForm) / T.form)) : 0;
    const mapAlpha = clamp01(t / T.intro) * (1 - 0.78 * formP);
    ctx.globalAlpha = mapAlpha;
    ctx.drawImage(mapLayer, 0, 0, W, H);
    ctx.globalAlpha = 1;

    ctx.lineWidth = 1.2;
    ctx.lineCap = "round";
    for (let i = 0; i < HOPS; i += 1) {
      if (s <= i) break;
      const f = Math.min(1, s - i);
      const arc = arcs[i];
      ctx.beginPath();
      ctx.moveTo(arc.a.x, arc.a.y);
      const steps = 28;
      for (let k = 1; k <= steps; k += 1) {
        const p = arcPoint(arc, (k / steps) * f);
        ctx.lineTo(p.x, p.y);
      }
      ctx.strokeStyle = `rgba(227, 155, 74, ${(f < 1 ? 0.7 : 0.38) * mapAlpha})`;
      ctx.stroke();
    }

    let current = -1;
    nodes.forEach((n, k) => {
      const arrived = t >= arrivalAt(k);
      if (arrived) current = k;
      const since = t - arrivalAt(k);
      ctx.beginPath();
      ctx.arc(n.x, n.y, arrived ? 3.4 : 2.2, 0, TAU);
      ctx.fillStyle = arrived
        ? `rgba(61, 184, 168, ${0.95 * mapAlpha + 0.05})`
        : `rgba(242, 238, 230, ${0.35 * mapAlpha})`;
      ctx.fill();
      if (arrived && since < 900) {
        const q = since / 900;
        ctx.beginPath();
        ctx.arc(n.x, n.y, 4 + easeOut(q) * 34, 0, TAU);
        ctx.strokeStyle = `rgba(61, 184, 168, ${(1 - q) * 0.8})`;
        ctx.lineWidth = 1.4;
        ctx.stroke();
      }
      if (arrived) {
        ctx.beginPath();
        ctx.arc(n.x, n.y, 8, 0, TAU);
        ctx.strokeStyle = `rgba(61, 184, 168, ${0.3 * mapAlpha})`;
        ctx.lineWidth = 1;
        ctx.stroke();
      }
    });

    const labelFade = 1 - clamp01((t - tHopsEnd) / 500);
    if (labelFade <= 0.01) return current;
    ctx.textAlign = "center";
    ctx.textBaseline = "alphabetic";
    nodes.forEach((n, k) => {
      if (k > current) return;
      const lx = Math.min(W - 56, Math.max(56, n.x));
      if (k === current) {
        const appear = easeOut(clamp01((t - arrivalAt(k)) / 260));
        const a = appear * labelFade;
        ctx.font = `600 13px ${GLYPH_FONT}`;
        ctx.fillStyle = `rgba(242, 238, 230, ${0.95 * a})`;
        ctx.fillText(`${n.country} · ${n.city}`, lx, n.y - 18 - appear * 4);
        ctx.font = '600 11px "Manrope", sans-serif';
        ctx.fillStyle = `rgba(61, 184, 168, ${0.9 * a})`;
        ctx.fillText(`${n.ms} ms`, lx, n.y + 22);
      } else {
        ctx.font = `500 11px ${GLYPH_FONT}`;
        ctx.fillStyle = `rgba(199, 212, 227, ${0.4 * labelFade * mapAlpha})`;
        ctx.fillText(n.country, lx, n.y - 14);
      }
    });
    return current;
  };

  const COLORS = [
    (a) => `rgba(255, 240, 214, ${a})`,
    (a) => `rgba(227, 155, 74, ${a})`,
    (a) => `rgba(61, 184, 168, ${a})`,
  ];

  const drawParticles = (t, s) => {
    ctx.globalCompositeOperation = "lighter";
    const moving = t < tHold;

    if (t < tForm && t > T.intro && s < HOPS) {
      const head = routePoint(s);
      const g = ctx.createRadialGradient(head.x, head.y, 0, head.x, head.y, 22);
      g.addColorStop(0, "rgba(255, 236, 200, 0.85)");
      g.addColorStop(0.4, "rgba(227, 155, 74, 0.35)");
      g.addColorStop(1, "rgba(227, 155, 74, 0)");
      ctx.fillStyle = g;
      ctx.beginPath();
      ctx.arc(head.x, head.y, 22, 0, TAU);
      ctx.fill();
    }

    for (let hue = 0; hue < 3; hue += 1) {
      if (moving) {
        ctx.beginPath();
        particles.forEach((p) => {
          if (p.hue !== hue) return;
          ctx.moveTo(p.px, p.py);
          ctx.lineTo(p.x, p.y);
        });
        ctx.strokeStyle = COLORS[hue](0.55);
        ctx.lineWidth = 1.3;
        ctx.stroke();
      }
      ctx.beginPath();
      particles.forEach((p) => {
        if (p.hue !== hue) return;
        const r = p.size * (p.scale || 1);
        ctx.moveTo(p.x + r, p.y);
        ctx.arc(p.x, p.y, r, 0, TAU);
      });
      ctx.fillStyle = COLORS[hue](moving ? 0.85 : 0.95);
      ctx.fill();
    }
    ctx.globalCompositeOperation = "source-over";
  };

  const drawBrand = (t) => {
    const a = easeOut(clamp01((t - tHold + 250) / 550));
    if (a <= 0) return;
    const { fs, cx, cy } = glyph;
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = `800 ${fs}px ${GLYPH_FONT}`;
    ctx.shadowColor = `rgba(227, 155, 74, ${0.45 * a})`;
    ctx.shadowBlur = 40;
    ctx.fillStyle = `rgba(242, 238, 230, ${0.14 * a})`;
    ctx.fillText("跃界", cx, cy);
    ctx.restore();

    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = `600 ${Math.max(12, Math.round(fs * 0.11))}px "Manrope", sans-serif`;
    ctx.fillStyle = `rgba(227, 155, 74, ${0.9 * a})`;
    ctx.fillText("H O P W O R L D", cx, cy + fs * 0.78 + (1 - a) * 8);
  };

  const frame = (now) => {
    if (finished) return;
    if (!startedAt) startedAt = now;
    const t = now - startedAt;
    const s = routeS(t);

    ctx.clearRect(0, 0, W, H);
    updateParticles(t);
    const current = drawMapAndRoutes(t, s);
    drawParticles(t, s);
    drawBrand(t);

    if (t < tHopsEnd + 120) {
      const k = Math.max(0, current);
      setCaption(k === 0 ? `起跳 · ${ROUTE[0].country}` : `跃迁 ${String(k).padStart(2, "0")} / ${String(HOPS).padStart(2, "0")} · ${ROUTE[k].country}`);
    } else if (t < tHold) {
      setCaption("汇聚成界");
    } else {
      setCaption("跃界 · HopWorld");
    }

    if (t >= tEnd) {
      finish();
      return;
    }
    raf = requestAnimationFrame(frame);
  };

  const skip = () => {
    cancelAnimationFrame(raf);
    finish();
  };

  try {
    layout();
    makeParticles();
  } catch (_) {
    finish();
    return;
  }

  let resizeTimer = 0;
  window.addEventListener("resize", () => {
    window.clearTimeout(resizeTimer);
    resizeTimer = window.setTimeout(() => {
      if (!finished) layout();
    }, 150);
  });
  skipBtn && skipBtn.addEventListener("click", skip, { once: true });
  document.addEventListener("keydown", (e) => {
    if (!finished && (e.key === "Escape" || e.key === "Enter")) skip();
  });
  raf = requestAnimationFrame(frame);
})();
