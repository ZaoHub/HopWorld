(() => {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const finePointer = window.matchMedia("(hover: hover) and (pointer: fine)").matches;

  const header = document.querySelector(".site-header");
  const progress = document.querySelector(".scroll-progress");

  let scrollQueued = false;
  const onScroll = () => {
    scrollQueued = false;
    const y = window.scrollY;
    if (header) header.classList.toggle("is-scrolled", y > 24);
    if (progress) {
      const max = document.documentElement.scrollHeight - window.innerHeight;
      progress.style.setProperty("--progress", max > 0 ? (y / max).toFixed(4) : "0");
    }
  };
  onScroll();
  window.addEventListener(
    "scroll",
    () => {
      if (scrollQueued) return;
      scrollQueued = true;
      requestAnimationFrame(onScroll);
    },
    { passive: true }
  );

  document.querySelectorAll(".feature-rail .feature-item").forEach((el, i) => el.style.setProperty("--d", String(i)));
  document.querySelectorAll(".protocol-chip").forEach((el, i) => el.style.setProperty("--i", String(i)));

  const countUp = (el) => {
    const target = Number(el.getAttribute("data-count")) || 0;
    if (reduce || target <= 0) return;
    const start = performance.now();
    const duration = 1100 + target * 20;
    const tick = (now) => {
      const k = Math.min(1, (now - start) / duration);
      el.textContent = String(Math.round(target * (1 - (1 - k) ** 3)));
      if (k < 1) requestAnimationFrame(tick);
    };
    el.textContent = "0";
    requestAnimationFrame(tick);
  };

  const onReveal = (el) => {
    el.classList.add("is-in");
    el.querySelectorAll("[data-count]").forEach(countUp);
  };

  const startReveals = () => {
    const reveals = document.querySelectorAll(".reveal");
    if (reduce || !("IntersectionObserver" in window)) {
      reveals.forEach((el) => el.classList.add("is-in"));
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            onReveal(entry.target);
            io.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.16, rootMargin: "0px 0px -8% 0px" }
    );
    reveals.forEach((el) => io.observe(el));
  };

  const startAmbient = () => {
    const canvas = document.querySelector("[data-ambient]");
    const ctx = canvas && canvas.getContext("2d");
    if (!ctx || reduce) return;

    let w = 0;
    let h = 0;
    let dots = [];
    let mouse = { x: -9999, y: -9999 };
    let raf = 0;
    const LINK = 130;

    const resize = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      w = window.innerWidth;
      h = window.innerHeight;
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      const count = Math.round(Math.min(70, Math.max(28, (w * h) / 22000)));
      dots = Array.from({ length: count }, () => ({
        x: Math.random() * w,
        y: Math.random() * h,
        vx: (Math.random() - 0.5) * 0.22,
        vy: (Math.random() - 0.5) * 0.22,
        r: 0.6 + Math.random() * 1.3,
        amber: Math.random() < 0.45,
      }));
    };

    const step = () => {
      ctx.clearRect(0, 0, w, h);
      for (const d of dots) {
        const mx = d.x - mouse.x;
        const my = d.y - mouse.y;
        const md = Math.hypot(mx, my);
        if (md < 160 && md > 0.1) {
          d.x += (mx / md) * 0.6;
          d.y += (my / md) * 0.6;
        }
        d.x += d.vx;
        d.y += d.vy;
        if (d.x < -10) d.x = w + 10;
        if (d.x > w + 10) d.x = -10;
        if (d.y < -10) d.y = h + 10;
        if (d.y > h + 10) d.y = -10;
      }
      ctx.lineWidth = 0.6;
      for (let i = 0; i < dots.length; i += 1) {
        for (let j = i + 1; j < dots.length; j += 1) {
          const a = dots[i];
          const b = dots[j];
          const dist = Math.hypot(a.x - b.x, a.y - b.y);
          if (dist < LINK) {
            ctx.strokeStyle = `rgba(199, 212, 227, ${(1 - dist / LINK) * 0.14})`;
            ctx.beginPath();
            ctx.moveTo(a.x, a.y);
            ctx.lineTo(b.x, b.y);
            ctx.stroke();
          }
        }
      }
      for (const d of dots) {
        ctx.beginPath();
        ctx.arc(d.x, d.y, d.r, 0, Math.PI * 2);
        ctx.fillStyle = d.amber ? "rgba(227, 155, 74, 0.55)" : "rgba(61, 184, 168, 0.5)";
        ctx.fill();
      }
      raf = requestAnimationFrame(step);
    };

    resize();
    window.addEventListener("resize", resize);
    if (finePointer) {
      window.addEventListener(
        "pointermove",
        (e) => {
          mouse = { x: e.clientX, y: e.clientY };
        },
        { passive: true }
      );
    }
    document.addEventListener("visibilitychange", () => {
      cancelAnimationFrame(raf);
      if (!document.hidden) raf = requestAnimationFrame(step);
    });
    canvas.classList.add("is-on");
    raf = requestAnimationFrame(step);
  };

  const afterIntro = () => {
    startReveals();
    startAmbient();
  };

  if (document.body.classList.contains("is-intro")) {
    document.addEventListener("hopworld:introdone", afterIntro, { once: true });
  } else {
    afterIntro();
  }

  const stage = document.querySelector(".shot-main");
  const main = document.querySelector("[data-shot-main]");
  const thumbs = document.querySelectorAll("[data-shot-src]");
  if (main && thumbs.length) {
    thumbs.forEach((thumb) => {
      thumb.addEventListener("click", () => {
        const src = thumb.getAttribute("data-shot-src");
        const alt = thumb.getAttribute("data-shot-alt") || "";
        if (!src || main.getAttribute("src") === src) return;
        thumbs.forEach((t) => t.classList.toggle("is-active", t === thumb));
        if (reduce || !stage) {
          main.src = src;
          main.alt = alt;
          return;
        }
        stage.classList.add("is-swapping");
        window.setTimeout(() => {
          const done = () => requestAnimationFrame(() => stage.classList.remove("is-swapping"));
          main.addEventListener("load", done, { once: true });
          main.addEventListener("error", done, { once: true });
          main.src = src;
          main.alt = alt;
          if (main.complete) done();
        }, 220);
      });
    });
  }

  if (stage && finePointer && !reduce) {
    stage.addEventListener("pointermove", (e) => {
      const r = stage.getBoundingClientRect();
      const px = (e.clientX - r.left) / r.width;
      const py = (e.clientY - r.top) / r.height;
      stage.classList.add("is-tilting");
      stage.style.setProperty("--ry", `${((px - 0.5) * 7).toFixed(2)}deg`);
      stage.style.setProperty("--rx", `${((0.5 - py) * 5).toFixed(2)}deg`);
      stage.style.setProperty("--mx", `${(px * 100).toFixed(1)}%`);
      stage.style.setProperty("--my", `${(py * 100).toFixed(1)}%`);
    });
    stage.addEventListener("pointerleave", () => {
      stage.classList.remove("is-tilting");
      stage.style.setProperty("--rx", "0deg");
      stage.style.setProperty("--ry", "0deg");
    });
  }
})();
