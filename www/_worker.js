export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const response = await env.ASSETS.fetch(request);

    if (response.status !== 404 || url.pathname === "/") {
      return response;
    }

    const home = new URL(request.url);
    home.pathname = "/";
    home.search = "";
    home.hash = "";

    return Response.redirect(home.toString(), 302);
  },
};
