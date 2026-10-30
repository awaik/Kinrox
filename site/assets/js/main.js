// Progressive enhancement only: the page is complete without JavaScript.
// No analytics, cookies, or network requests.
(() => {
  document.documentElement.classList.add("js");

  // Links already work without JavaScript and preserve the current page.
  // Keep section anchors and query parameters when switching language as well.
  const languages = document.querySelector(".language-menu");
  const updateLanguageLinks = () => {
    languages?.querySelectorAll("[data-language]").forEach((link) => {
      const url = new URL(link.href);
      url.search = window.location.search;
      url.hash = window.location.hash === "#languages" ? "" : window.location.hash;
      link.href = url.href;
    });
  };
  updateLanguageLinks();
  window.addEventListener("hashchange", updateLanguageLinks);
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && languages?.open) {
      languages.open = false;
      languages.querySelector("summary").focus();
    }
  });
  document.addEventListener("click", (event) => {
    if (languages?.open && !languages.contains(event.target)) languages.open = false;
  });

  const nav = document.querySelector(".nav");
  const onScroll = () => nav?.classList.toggle("is-scrolled", window.scrollY > 8);
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  const targets = document.querySelectorAll("[data-reveal]");
  if (!("IntersectionObserver" in window)) {
    targets.forEach((el) => el.classList.add("is-visible"));
    return;
  }
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      }
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.12 }
  );
  targets.forEach((el) => observer.observe(el));
})();
