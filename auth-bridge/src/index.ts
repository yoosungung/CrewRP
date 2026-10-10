export interface Env {
  GITHUB_CLIENT_ID: string;
  GITHUB_CLIENT_SECRET: string;
  DISCORD_CLIENT_ID: string;
  DISCORD_CLIENT_SECRET: string;
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

async function parseTokenRequest(request: Request): Promise<TokenRequest | Response> {
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
  return payload;
}

async function handleGitHubToken(request: Request, env: Env): Promise<Response> {
  const parsed = await parseTokenRequest(request);
  if (parsed instanceof Response) return parsed;
  const { code, code_verifier, redirect_uri } = parsed;
  if (!allowedRedirects(env).has(redirect_uri!)) {
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

async function handleDiscordToken(request: Request, env: Env): Promise<Response> {
  if (!env.DISCORD_CLIENT_ID || !env.DISCORD_CLIENT_SECRET) {
    return json(503, { error: "discord_not_configured" });
  }
  const parsed = await parseTokenRequest(request);
  if (parsed instanceof Response) return parsed;
  const { code, code_verifier, redirect_uri } = parsed;
  if (!allowedRedirects(env).has(redirect_uri!)) {
    return json(400, { error: "redirect_uri_not_allowed" });
  }

  const body = new URLSearchParams({
    client_id: env.DISCORD_CLIENT_ID,
    client_secret: env.DISCORD_CLIENT_SECRET,
    grant_type: "authorization_code",
    code: code!,
    redirect_uri: redirect_uri!,
    code_verifier: code_verifier!,
  });

  const tokenResponse = await fetch("https://discord.com/api/oauth2/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  const tokenJson = (await tokenResponse.json()) as {
    access_token?: string;
    error?: string;
  };
  if (!tokenResponse.ok || !tokenJson.access_token) {
    return json(tokenResponse.status || 400, {
      error: tokenJson.error ?? "discord_token_failed",
    });
  }

  const meResponse = await fetch("https://discord.com/api/users/@me", {
    headers: { Authorization: `Bearer ${tokenJson.access_token}` },
  });
  const me = (await meResponse.json()) as {
    id?: string;
    username?: string;
    error?: string;
  };
  if (!meResponse.ok || !me.id || !me.username) {
    return json(meResponse.status || 400, {
      error: me.error ?? "discord_me_failed",
    });
  }

  return json(200, { id: me.id, username: me.username });
}

export async function handleRequest(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (request.method !== "POST") {
    return json(404, { error: "not_found" });
  }
  if (url.pathname === "/oauth/token") {
    return handleGitHubToken(request, env);
  }
  if (url.pathname === "/oauth/discord/token") {
    return handleDiscordToken(request, env);
  }
  return json(404, { error: "not_found" });
}

export default {
  fetch: handleRequest,
};
