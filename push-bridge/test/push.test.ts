import { describe, it, expect, vi } from "vitest";
import { mapWebhook, verifySignature, handleRequest, type Env } from "../src/index";

describe("mapWebhook", () => {
  it("maps discussion created to notice", () => {
    expect(mapWebhook("discussion", { action: "created", discussion: { title: "주간" } })).toEqual({
      kind: "notice",
      title: "주간",
    });
  });

  it("skips unknown events", () => {
    expect(mapWebhook("push", { action: "created" })).toBeNull();
  });
});

describe("verifySignature", () => {
  it("accepts valid hmac", async () => {
    const secret = "s3cret";
    const body = "{\"ok\":true}";
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
    const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
    expect(await verifySignature(secret, body, `sha256=${hex}`)).toBe(true);
  });
});

describe("handleRequest", () => {
  it("sends FCM for assigned issue", async () => {
    const store = new Map<string, string>([["u1", "device-token"]]);
    const env: Env = {
      WEBHOOK_SECRET: "s3cret",
      FCM_SERVER_KEY: "fcm-key",
      DEVICE_TOKENS: {
        get: async (k: string) => store.get(k) ?? null,
        put: async (k: string, v: string) => {
          store.set(k, v);
        },
        list: async () => ({ keys: [...store.keys()].map((name) => ({ name })), list_complete: true }),
      } as unknown as KVNamespace,
    };
    const body = JSON.stringify({ action: "assigned", issue: { title: "영수증" } });
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(env.WEBHOOK_SECRET),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
    const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
    const fetchMock = vi.fn(async () => new Response("{}", { status: 200 }));
    const response = await handleRequest(
      new Request("https://push.example/webhook", {
        method: "POST",
        headers: {
          "X-GitHub-Event": "issues",
          "X-Hub-Signature-256": `sha256=${hex}`,
        },
        body,
      }),
      env,
      fetchMock as unknown as typeof fetch,
    );
    expect(response.status).toBe(200);
    expect(fetchMock).toHaveBeenCalledOnce();
    const [, init] = fetchMock.mock.calls[0]!;
    expect(JSON.parse(String(init?.body)).to).toBe("device-token");
  });
});
