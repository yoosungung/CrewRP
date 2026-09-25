export interface Env {
  WEBHOOK_SECRET: string;
  DEVICE_TOKENS: KVNamespace;
  FCM_SERVER_KEY: string;
}

export type PushEvent =
  | { kind: "notice"; title: string }
  | { kind: "thread"; title: string }
  | { kind: "task_assigned"; title: string };

export function mapWebhook(event: string, payload: Record<string, unknown>): PushEvent | null {
  if (event === "discussion" && payload.action === "created") {
    const discussion = payload.discussion as { title?: string } | undefined;
    return { kind: "notice", title: discussion?.title ?? "새 공지" };
  }
  if (
    (event === "issue_comment" || event === "discussion_comment") &&
    payload.action === "created"
  ) {
    return { kind: "thread", title: "스레드 톡" };
  }
  if (event === "issues" && payload.action === "assigned") {
    const issue = payload.issue as { title?: string } | undefined;
    return { kind: "task_assigned", title: issue?.title ?? "할 일 배정" };
  }
  return null;
}

export async function verifySignature(
  secret: string,
  body: string,
  signatureHeader: string | null,
): Promise<boolean> {
  if (!signatureHeader?.startsWith("sha256=")) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(String(secret)),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `sha256=${hex}` === signatureHeader;
}

export async function handleRequest(request: Request, env: Env, fetchImpl: typeof fetch = fetch): Promise<Response> {
  if (request.method === "POST" && new URL(request.url).pathname === "/devices") {
    const { userId, token } = (await request.json()) as { userId?: string; token?: string };
    if (!userId || !token) return Response.json({ error: "missing_fields" }, { status: 400 });
    await env.DEVICE_TOKENS.put(userId, token);
    return Response.json({ ok: true });
  }

  if (request.method !== "POST" || new URL(request.url).pathname !== "/webhook") {
    return Response.json({ error: "not_found" }, { status: 404 });
  }

  const body = await request.text();
  const signature = request.headers.get("X-Hub-Signature-256");
  if (!(await verifySignature(env.WEBHOOK_SECRET, body, signature))) {
    return Response.json({ error: "bad_signature" }, { status: 401 });
  }

  const event = request.headers.get("X-GitHub-Event") ?? "";
  const payload = JSON.parse(body) as Record<string, unknown>;
  const mapped = mapWebhook(event, payload);
  if (!mapped) return Response.json({ ok: true, skipped: true });

  const tokens: string[] = [];
  let cursor: string | undefined;
  do {
    const page = await env.DEVICE_TOKENS.list({ cursor });
    for (const key of page.keys) {
      const token = await env.DEVICE_TOKENS.get(key.name);
      if (token) tokens.push(token);
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);

  for (const token of tokens) {
    await fetchImpl("https://fcm.googleapis.com/fcm/send", {
      method: "POST",
      headers: {
        Authorization: `key=${env.FCM_SERVER_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        to: token,
        notification: {
          title: mapped.kind === "notice" ? "새 공지" : mapped.kind === "thread" ? "스레드 톡" : "할 일 배정",
          body: mapped.title,
        },
      }),
    });
  }

  return Response.json({ ok: true, sent: tokens.length });
}

export default {
  fetch: (request: Request, env: Env) => handleRequest(request, env),
};
