// Added to the files service's (dufs's) own pages by
// PurpleFlowWeb.Plugs.FilesProxy, so they sit inside the app seamlessly.
(() => {
  const root = document.documentElement;

  // Opened on its own? Show it inside the app's frame instead.
  if (window.top === window && location.pathname.startsWith("/fs")) {
    location.replace("/files" + location.pathname.slice(3) + location.search);
    return;
  }

  // The app's theme: the same localStorage key as root.html.heex (same origin).
  const applyTheme = () => {
    let theme = null;
    try { theme = localStorage.getItem("phx:theme"); } catch (_) {}
    if (!theme || theme === "system") {
      theme = matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
    }
    root.setAttribute("data-theme", theme);
  };
  applyTheme();
  window.addEventListener("storage", (e) => e.key === "phx:theme" && applyTheme());
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", applyTheme);

  // dufs opens files in new tabs; in the app, open them here, in its editor.
  const keepInFrame = (el) => {
    el.querySelectorAll("a[target=_blank]").forEach((a) => {
      a.removeAttribute("target");
      const href = a.getAttribute("href") || "";
      if (a.closest(".cell-name") && !href.includes("?")) a.setAttribute("href", href + "?edit");
    });
  };
  const start = () => {
    keepInFrame(document.body);
    new MutationObserver(() => keepInFrame(document.body))
      .observe(document.body, { childList: true, subtree: true });
    document.title = document.title.replace(/ - Dufs$/, "");
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();

  // Ctrl/Cmd+S saves in the editor.
  document.addEventListener("keydown", (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") {
      const save = document.querySelector(".save-btn:not(.hidden)");
      if (save) {
        e.preventDefault();
        save.click();
      }
    }
  });
})();
