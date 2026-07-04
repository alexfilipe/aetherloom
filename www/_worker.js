const existingPaths = new Set([
  "/",
  "/assets/app-icon.png",
  "/assets/apple-touch-icon.png",
  "/assets/favicon-16.png",
  "/assets/favicon-32.png",
  "/assets/icon-192.png",
  "/assets/icon-512.png",
  "/assets/mark-black.png",
  "/assets/mark-gradient.png",
  "/assets/mark-white.png",
  "/assets/social-preview.png",
  "/assets/ui-activity.png",
  "/assets/ui-conflicts.png",
  "/assets/ui-overview-scanning.png",
  "/assets/ui-overview.png",
  "/assets/ui-settings.png",
  "/assets/ui-sync-sets.png",
  "/index.html",
  "/robots.txt",
  "/site.webmanifest",
  "/sitemap.xml",
]);

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (existingPaths.has(url.pathname)) {
      return env.ASSETS.fetch(request);
    }

    const home = new URL(request.url);
    home.pathname = "/";
    home.search = "";
    home.hash = "";

    return Response.redirect(home.toString(), 302);
  },
};
