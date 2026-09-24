import { describe, it, expect, vi, beforeEach } from "vitest";
import { handleRequest, type Env } from "../src/index";

const testEnv: Env = {
  GITHUB_CLIENT_ID: "test-client-id",
  GITHUB_CLIENT_SECRET: "test-client-secret",
  ALLOWED_REDIRECT_URIS: "crewrp://oauth/callback,https://crewrp.app/oauth/callback",
};

describe("POST /oauth/token", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("exchanges code with GitHub and returns token without storing it", async () => {
    const fetchMock = vi.fn(async () =>
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
