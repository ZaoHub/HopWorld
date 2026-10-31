(() => {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  const finishIntro = () => {
    const intro = document.getElementById("intro");
    document.body.classList.remove("is-intro");
    if (!intro) return;
    intro.classList.add("is-done");
    intro.setAttribute("aria-hidden", "true");
    window.setTimeout(() => intro.remove(), 800);
  };

  const runIntro = () => {
    const intro = document.getElementById("intro");
    const canvas = document.querySelector("[data-intro-canvas]");
    const caption = document.querySelector("[data-intro-caption]");
    const skipBtn = document.querySelector("[data-intro-skip]");
    if (!intro || !canvas) {
      finishIntro();
      return;
    }

    const forceIntro = /(?:\?|&)intro=1(?:&|$)/.test(location.search);
    if (!forceIntro && (reduce || sessionStorage.getItem("hopworld-intro-seen") === "1")) {
      finishIntro();
      return;
    }

    const ctx = canvas.getContext("2d", { alpha: true });
    if (!ctx) {
      finishIntro();
      return;
    }

    const cities = [
      { name: "东京", x: 0.78, y: 0.32 },
      { name: "新加坡", x: 0.7, y: 0.62 },
      { name: "香港", x: 0.72, y: 0.42 },
      { name: "洛杉矶", x: 0.16, y: 0.4 },
      { name: "法兰克福", x: 0.48, y: 0.28 },
      { name: "悉尼", x: 0.84, y: 0.78 },
      { name: "伦敦", x: 0.42, y: 0.24 },
      { name: "圣保罗", x: 0.28, y: 0.72 },
    ];

    let width = 0;
    let height = 0;
    let dpr = 1;
    let nodes = [];
    let particles = [];
    let targets = [];
    let startedAt = 0;
    let raf = 0;
    let finished = false;
    let routeFlash = 0;

    const phases = {
      hopEnd: 2200,
      formEnd: 3800,
      holdEnd: 4600,
      fadeEnd: 5400,
    };

    const resize = () => {
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      width = window.innerWidth;
      height = window.innerHeight;
      canvas.width = Math.floor(width * dpr);
      canvas.height = Math.floor(height * dpr);
      canvas.style.width = `${width}px`;
      canvas.style.height = `${height}px`;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      nodes = cities.map((c) => ({
        name: c.name,
        x: c.x * width,
        y: c.y * height,
      }));
      targets = sampleGlyphTargets();
      if (particles.length) bindFormTargets();
    };

    const sampleGlyphTargets = () => {
      const off = document.createElement("canvas");
      const fontSize = Math.min(width * 0.28, height * 0.22, 168);
      off.width = Math.ceil(width);
      off.height = Math.ceil(height);
      const octx = off.getContext("2d");
      if (!octx) return [];
      octx.clearRect(0, 0, off.width, off.height);
      octx.fillStyle = "#fff";
      octx.textAlign = "center";
      octx.textBaseline = "middle";
      octx.font = `800 ${fontSize}px "Syne", "PingFang SC", "Hiragino Sans GB", sans-serif`;
      octx.fillText("跃界", width * 0.5, height * 0.46);
      const { data } = octx.getImageData(0, 0, off.width, off.height);
      const pts = [];
      const step = Math.max(3, Math.floor(fontSize / 28));
      for (let y = 0; y < off.height; y += step) {
        for (let x = 0; x < off.width; x += step) {
          const a = data[(y * off.width + x) * 4 + 3];
          if (a > 140) {
            pts.push({
              x: x + (Math.random() - 0.5) * 1.2,
              y: y + (Math.random() - 0.5) * 1.2,
            });
          }
        }
      }
      return pts;
    };

    const rand = (min, max) => min + Math.random() * (max - min);

    const makeParticle = (i) => {
      const from = nodes[i % nodes.length];
      const to = nodes[(i + 1 + Math.floor(Math.random() * (nodes.length - 1))) % nodes.length];
      const midX = (from.x + to.x) / 2 + rand(-90, 90);
      const midY = Math.min(from.y, to.y) - rand(40, 140);
      return {
        x: from.x,
        y: from.y,
        from,
        to,
        cx: midX,
        cy: midY,
        progress: Math.random() * 0.15,
        speed: rand(0.0018, 0.0034),
        hopsLeft: 1 + Math.floor(Math.random() * 2),
        size: rand(1.2, 2.8),
        hue: Math.random() > 0.45 ? "amber" : "teal",
        twinkle: Math.random() * Math.PI * 2,
        tx: width / 2,
        ty: height / 2,
        formDelay: Math.random() * 0.35,
      };
    };

    const nextHop = (p) => {
      const from = p.to;
      let to = nodes[Math.floor(Math.random() * nodes.length)];
      if (nodes.length > 1) {
        let guard = 0;
        while (to === from && guard < 6) {
          to = nodes[Math.floor(Math.random() * nodes.length)];
          guard += 1;
        }
      }
      p.from = from;
      p.to = to;
      p.cx = (from.x + to.x) / 2 + rand(-110, 110);
      p.cy = Math.min(from.y, to.y) - rand(50, 160);
      p.progress = 0;
      p.speed = rand(0.002, 0.0036);
      p.hopsLeft -= 1;
      routeFlash = 1;
    };

    const bindFormTargets = () => {
      if (!targets.length) return;
      const count = Math.min(particles.length, targets.length);
      for (let i = 0; i < particles.length; i += 1) {
        const t = targets[i % count];
        particles[i].tx = t.x;
        particles[i].ty = t.y;
      }
    };

    const quad = (a, b, c, t) => {
      const u = 1 - t;
      return u * u * a + 2 * u * t * b + t * t * c;
    };

    const easeOutCubic = (t) => 1 - (1 - t) ** 3;

    const setCaption = (text) => {
      if (caption) caption.textContent = text;
    };

    const particleCount = () => {
      const area = width * height;
      if (area < 500000) return 220;
      if (area < 1200000) return 320;
      return 420;
    };

    const endIntro = () => {
      if (finished) return;
      finished = true;
      cancelAnimationFrame(raf);
      sessionStorage.setItem("hopworld-intro-seen", "1");
      finishIntro();
    };

    const drawBackground = (t) => {
      ctx.clearRect(0, 0, width, height);

      const glow = Math.min(1, t / 900);
      const g = ctx.createRadialGradient(
        width * 0.5,
        height * 0.45,
        20,
        width * 0.5,
        height * 0.45,
        Math.max(width, height) * 0.55
      );
      g.addColorStop(0, `rgba(61, 184, 168, ${0.08 * glow})`);
      g.addColorStop(0.45, `rgba(227, 155, 74, ${0.05 * glow})`);
      g.addColorStop(1, "rgba(0,0,0,0)");
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, width, height);

      nodes.forEach((n, i) => {
        const pulse = 0.55 + Math.sin(t * 0.004 + i) * 0.2;
        ctx.beginPath();
        ctx.arc(n.x, n.y, 3.2, 0, Math.PI * 2);
        ctx.fillStyle = `rgba(242, 238, 230, ${0.55 * pulse})`;
        ctx.fill();
        ctx.beginPath();
        ctx.arc(n.x, n.y, 10 + pulse * 4, 0, Math.PI * 2);
        ctx.strokeStyle = `rgba(61, 184, 168, ${0.28 * pulse})`;
        ctx.lineWidth = 1;
        ctx.stroke();

        const labelAlpha = t < phases.hopEnd ? 0.55 : Math.max(0, 0.55 - (t - phases.hopEnd) / 700);
        if (labelAlpha > 0.02) {
          ctx.font = '500 11px "Manrope", "PingFang SC", sans-serif';
          ctx.fillStyle = `rgba(199, 212, 227, ${labelAlpha})`;
          ctx.textAlign = "center";
          ctx.fillText(n.name, n.x, n.y - 14);
        }
      });

      if (routeFlash > 0.02) {
        for (let i = 0; i < 4; i += 1) {
          const a = nodes[i % nodes.length];
          const b = nodes[(i + 3) % nodes.length];
          ctx.beginPath();
          ctx.moveTo(a.x, a.y);
          ctx.quadraticCurveTo(
            (a.x + b.x) / 2,
            Math.min(a.y, b.y) - 80,
            b.x,
            b.y
          );
          ctx.strokeStyle = `rgba(227, 155, 74, ${0.12 * routeFlash})`;
          ctx.lineWidth = 1;
          ctx.stroke();
        }
        routeFlash *= 0.94;
      }
    };

    const drawParticles = (t) => {
      const forming = t >= phases.hopEnd;
      const hold = t >= phases.formEnd;
      const fade = t >= phases.holdEnd ? (t - phases.holdEnd) / (phases.fadeEnd - phases.holdEnd) : 0;

      particles.forEach((p) => {
        if (!forming) {
          p.progress += p.speed * 16;
          if (p.progress >= 1) {
            p.x = p.to.x;
            p.y = p.to.y;
            if (p.hopsLeft > 0) nextHop(p);
            else p.progress = 1;
          } else {
            p.x = quad(p.from.x, p.cx, p.to.x, p.progress);
            p.y = quad(p.from.y, p.cy, p.to.y, p.progress);
          }
        } else {
          const local = Math.min(1, Math.max(0, (t - phases.hopEnd) / 1400 - p.formDelay));
          const e = easeOutCubic(local);
          p.x += (p.tx - p.x) * (0.08 + e * 0.18);
          p.y += (p.ty - p.y) * (0.08 + e * 0.18);
        }

        const flicker = 0.65 + Math.sin(t * 0.01 + p.twinkle) * 0.35;
        const alpha = Math.max(0, (hold ? 0.95 : 0.75) * flicker * (1 - fade));
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.size * (hold ? 1.15 : 1), 0, Math.PI * 2);
        ctx.fillStyle =
          p.hue === "amber"
            ? `rgba(227, 155, 74, ${alpha})`
            : `rgba(61, 184, 168, ${alpha})`;
        ctx.fill();

        if (forming && !hold) {
          ctx.beginPath();
          ctx.arc(p.x, p.y, p.size * 2.4, 0, Math.PI * 2);
          ctx.fillStyle =
            p.hue === "amber"
              ? `rgba(227, 155, 74, ${alpha * 0.18})`
              : `rgba(61, 184, 168, ${alpha * 0.18})`;
          ctx.fill();
        }
      });

      if (hold && fade < 0.85) {
        const brandAlpha = Math.min(1, (t - phases.formEnd) / 350) * (1 - fade);
        ctx.textAlign = "center";
        ctx.fillStyle = `rgba(242, 238, 230, ${0.55 * brandAlpha})`;
        ctx.font = '600 14px "Manrope", sans-serif';
        ctx.fillText("HopWorld", width * 0.5, height * 0.46 + Math.min(width * 0.16, 96));
      }
    };

    const frame = (now) => {
      if (finished) return;
      if (!startedAt) startedAt = now;
      const t = now - startedAt;

      if (t < phases.hopEnd) setCaption("跨国跃迁");
      else if (t < phases.formEnd) setCaption("汇聚成界");
      else setCaption("跃界");

      drawBackground(t);
      drawParticles(t);

      if (t >= phases.fadeEnd) {
        endIntro();
        return;
      }
      raf = requestAnimationFrame(frame);
    };

    try {
      resize();
      particles = Array.from({ length: particleCount() }, (_, i) => makeParticle(i));
      bindFormTargets();
      window.addEventListener("resize", resize);
      skipBtn?.addEventListener("click", endIntro, { once: true });
      raf = requestAnimationFrame(frame);
    } catch (_) {
      endIntro();
    }
  };

  try {
    runIntro();
  } catch (_) {
    finishIntro();
  }

  const header = document.querySelector(".site-header");
  const onScroll = () => {
    if (!header) return;
    header.classList.toggle("is-scrolled", window.scrollY > 24);
  };
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  const heroImg = document.querySelector(".hero-media img");
  const canParallax = heroImg && !reduce && window.matchMedia("(min-width: 641px)").matches;
  if (canParallax) {
    window.addEventListener(
      "scroll",
      () => {
        const y = Math.min(window.scrollY, window.innerHeight);
        heroImg.style.transform = `scale(1.06) translate3d(0, ${y * 0.12}px, 0)`;
      },
      { passive: true }
    );
  }

  const reveals = document.querySelectorAll(".reveal");
  if (reduce) {
    reveals.forEach((el) => el.classList.add("is-in"));
  } else if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-in");
            io.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.16, rootMargin: "0px 0px -8% 0px" }
    );
    reveals.forEach((el) => io.observe(el));
  } else {
    reveals.forEach((el) => el.classList.add("is-in"));
  }

  const main = document.querySelector("[data-shot-main]");
  const thumbs = document.querySelectorAll("[data-shot-src]");
  if (main && thumbs.length) {
    thumbs.forEach((thumb) => {
      thumb.addEventListener("click", () => {
        const src = thumb.getAttribute("data-shot-src");
        const alt = thumb.getAttribute("data-shot-alt") || "";
        if (!src) return;
        main.src = src;
        main.alt = alt;
        thumbs.forEach((t) => t.classList.toggle("is-active", t === thumb));
      });
    });
  }
})();
