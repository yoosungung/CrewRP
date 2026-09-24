export interface Env {
  GITHUB_CLIENT_ID: string;
  GITHUB_CLIENT_SECRET: string;
  ALLOWED_REDIRECT_URIS: string;
}

type TokenRequest = {
  code?: string;
  code_verifier?: string;
  redirect_uri?: string;
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function allowedRedirects(env: Env): Set<string> {
  return new Set(
    env.ALLOWED_REDIRECT_URIS.split(",")
      .map((s) => s.trim())
      .filter(Boolean),
  );
}

export async function handleRequest(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (request.method !== "POST" || url.pathname !== "/oauth/token") {
    return json(404, { error: "not_found" });
  }

  let payload: TokenRequest;
  try {
    payload = (await request.json()) as TokenRequest;
  } catch {
    return json(400, { error: "invalid_json" });
  }

  const { code, code_verifier, redirect_uri } = payload;
  if (!code || !code_verifier || !redirect_uri) {
    return json(400, { error: "missing_fields" });
  }
  if (!allowedRedirects(env).has(redirect_uri)) {
    return json(400, { error: "redirect_uri_not_allowed" });
  }

  const githubResponse = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      client_id: env.GITHUB_CLIENT_ID,
      client_secret: env.GITHUB_CLIENT_SECRET,
      code,
      code_verifier,
      redirect_uri,
    }),
  });

  const githubBody = await githubResponse.text();
  return new Response(githubBody, {
    status: githubResponse.status,
    headers: { "Content-Type": "application/json" },
  });
}

export default {
  fetch: handleRequest,
};
