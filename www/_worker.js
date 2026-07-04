export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const response = await env.ASSETS.fetch(request);

    if (url.pathname === "/" || url.pathname === "/index.html") {
      return response;
    }

    const contentType = response.headers.get("content-type") || "";
    if (response.status === 404 || contentType.includes("text/html")) {
      return redirectHome(request);
    }

    return response;
  },
};

function redirectHome(request) {
  const home = new URL(request.url);
  home.pathname = "/";
  home.search = "";
  home.hash = "";

  return Response.redirect(home.toString(), 302);
}
