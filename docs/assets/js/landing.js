(() => {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

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
