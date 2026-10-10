import { describe, it, expect, vi, beforeEach } from "vitest";
import { handleRequest, type Env } from "../src/index";

const testEnv: Env = {
  GITHUB_CLIENT_ID: "test-client-id",
  GITHUB_CLIENT_SECRET: "test-client-secret",
  DISCORD_CLIENT_ID: "discord-client-id",
  DISCORD_CLIENT_SECRET: "discord-client-secret",
  ALLOWED_REDIRECT_URIS:
    "crewrp://oauth/callback,crewrp://oauth/discord,discord-discord-client-id:/authorize/callback,https://crewrp.app/oauth/callback",
};

describe("POST /oauth/token", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("exchanges code with GitHub and returns token without storing it", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            access_token: "gho_test_token",
            token_type: "bearer",
            scope: "read:org",
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        ),
    );
    vi.stubGlobal("fetch", fetchMock);

    const request = new Request("https://auth.example/oauth/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        code: "abc",
        code_verifier: "verifier-value-with-enough-entropy-123456",
        redirect_uri: "crewrp://oauth/callback",
      }),
    });
    const response = await handleRequest(request, testEnv);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      access_token: "gho_test_token",
      token_type: "bearer",
      scope: "read:org",
    });

    expect(fetchMock).toHaveBeenCalledOnce();
    const [url, init] = fetchMock.mock.calls[0]!;
    expect(url).toBe("https://github.com/login/oauth/access_token");
    expect(init?.method).toBe("POST");
    expect(JSON.parse(String(init?.body))).toEqual({
      client_id: "test-client-id",
      client_secret: "test-client-secret",
      code: "abc",
      code_verifier: "verifier-value-with-enough-entropy-123456",
      redirect_uri: "crewrp://oauth/callback",
    });
  });

  it("rejects disallowed redirect_uri", async () => {
    const response = await handleRequest(
      new Request("https://auth.example/oauth/token", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          code: "abc",
          code_verifier: "verifier",
          redirect_uri: "https://evil.example/callback",
        }),
      }),
      testEnv,
    );
    expect(response.status).toBe(400);
  });

  it("rejects missing fields", async () => {
    const response = await handleRequest(
      new Request("https://auth.example/oauth/token", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: "abc" }),
      }),
      testEnv,
    );
    expect(response.status).toBe(400);
  });
});

describe("POST /oauth/discord/token", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("exchanges code, fetches @me, returns id and username only", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === "https://discord.com/api/oauth2/token") {
        return new Response(JSON.stringify({ access_token: "discord_at" }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      if (url === "https://discord.com/api/users/@me") {
        return new Response(JSON.stringify({ id: "99", username: "crewmate" }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      throw new Error(`unexpected ${url}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    const response = await handleRequest(
      new Request("https://auth.example/oauth/discord/token", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          code: "dc",
          code_verifier: "verifier-discord",
          redirect_uri: "discord-discord-client-id:/authorize/callback",
        }),
      }),
      testEnv,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ id: "99", username: "crewmate" });

    const tokenCall = fetchMock.mock.calls[0]!;
    expect(String(tokenCall[0])).toBe("https://discord.com/api/oauth2/token");
    const form = new URLSearchParams(String(tokenCall[1]?.body));
    expect(form.get("client_id")).toBe("discord-client-id");
    expect(form.get("client_secret")).toBe("discord-client-secret");
    expect(form.get("code")).toBe("dc");
    expect(form.get("code_verifier")).toBe("verifier-discord");
    expect(form.get("redirect_uri")).toBe("discord-discord-client-id:/authorize/callback");

    const meCall = fetchMock.mock.calls[1]!;
    expect(String(meCall[0])).toBe("https://discord.com/api/users/@me");
    const headers = meCall[1]?.headers as Record<string, string>;
    expect(headers.Authorization).toBe("Bearer discord_at");
  });

  it("rejects disallowed discord redirect_uri", async () => {
    const response = await handleRequest(
      new Request("https://auth.example/oauth/discord/token", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          code: "dc",
          code_verifier: "v",
          redirect_uri: "https://evil.example/discord",
        }),
      }),
      testEnv,
    );
    expect(response.status).toBe(400);
  });

  it("returns 503 when discord secrets missing", async () => {
    const response = await handleRequest(
      new Request("https://auth.example/oauth/discord/token", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          code: "dc",
          code_verifier: "v",
          redirect_uri: "discord-discord-client-id:/authorize/callback",
        }),
      }),
      { ...testEnv, DISCORD_CLIENT_ID: "", DISCORD_CLIENT_SECRET: "" },
    );
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "discord_not_configured" });
  });
});
