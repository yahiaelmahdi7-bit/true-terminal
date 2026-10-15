// True relay: a blind mailbox. It stores and forwards sealed envelopes between True installs and cannot read, forge,
// replay or redirect them (the keys are pinned on the clients at pairing). One Durable Object per mailbox, WebSocket
// Hibernation so idle sockets cost nothing. Blob contents are never logged.
import { DurableObject } from "cloudflare:workers";

export interface Env {
  MAILBOX: DurableObjectNamespace<Mailbox>;
  /** Test knobs; production leaves them unset. */
  AUTH_TIMEOUT_MS?: string;
  TTL_MS?: string;
}

export const VERSION = "1";
export const MAX_BLOB = 192 * 1024;        // base64 characters
export const MAX_QUEUED = 200;
export const MAX_BYTES = 8 * 1024 * 1024;
export const MAX_SOCKETS = 4;
export const MAX_UNAUTH = 12;
export const SENDS_PER_MIN = 60;
const DEFAULT_TTL_MS = 7 * 24 * 3600 * 1000;
const DEFAULT_AUTH_MS = 5000;
const MAX_FRAME = MAX_BLOB + 1024;

const MAILBOX_RE = /^[0-9a-f]{32}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const B64_RE = /^[A-Za-z0-9+/_-]+={0,2}$/;

export function b64decode(s: string): Uint8Array | null {
  if (!B64_RE.test(s)) return null;
  try {
    const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/"));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch { return null; }
}

export async function mailboxId(pub: Uint8Array): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", pub));
  return [...h.slice(0, 16)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

interface Att { m: string; host: string; nonce: string; t0: number; authed: boolean; win: number; n: number }

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/v1/health") return Response.json({ ok: true, version: VERSION });
    if (url.pathname === "/v1/connect") {
      if (req.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("expected websocket", { status: 426 });
      const m = url.searchParams.get("m") ?? "";
      if (!MAILBOX_RE.test(m)) return new Response("bad mailbox", { status: 400 });
      const stub = env.MAILBOX.get(env.MAILBOX.idFromName(m));
      const fwd = new Request(req);
      fwd.headers.set("x-mailbox", m);                 // set here so a client cannot choose it
      return stub.fetch(fwd);
    }
    return new Response("not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;

export class Mailbox extends DurableObject<Env> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    ctx.blockConcurrencyWhile(async () => {
      this.sql.exec(`CREATE TABLE IF NOT EXISTS msgs (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, frm TEXT NOT NULL,
        blob TEXT NOT NULL, size INTEGER NOT NULL, exp INTEGER NOT NULL)`);
    });
  }

  private get ttl() { return Number(this.env.TTL_MS) || DEFAULT_TTL_MS; }
  private get authMs() { return Number(this.env.AUTH_TIMEOUT_MS) || DEFAULT_AUTH_MS; }

  async fetch(req: Request): Promise<Response> {
    const m = req.headers.get("x-mailbox") ?? "";
    if (!MAILBOX_RE.test(m) || req.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("bad request", { status: 400 });
    const socks = this.ctx.getWebSockets();
    const authed = socks.filter((s) => (s.deserializeAttachment() as Att | null)?.authed).length;
    if (authed >= MAX_SOCKETS || socks.length >= MAX_UNAUTH) return new Response("too many connections", { status: 429 });
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    const nonceBytes = crypto.getRandomValues(new Uint8Array(32));
    const nonce = btoa(String.fromCharCode(...nonceBytes));
    const att: Att = { m, host: new URL(req.url).host, nonce, t0: Date.now(), authed: false, win: Date.now(), n: 0 };
    server.serializeAttachment(att);
    server.send(JSON.stringify({ t: "challenge", nonce }));
    await this.schedule();
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, data: string | ArrayBuffer): Promise<void> {
    const att = ws.deserializeAttachment() as Att | null;
    if (!att || typeof data !== "string" || data.length > MAX_FRAME) return void ws.close(1009, "frame");
    let msg: any;
    try { msg = JSON.parse(data); } catch { return void ws.close(1008, "schema"); }
    if (!msg || typeof msg !== "object" || typeof msg.t !== "string") return void ws.close(1008, "schema");
    if (!att.authed) {
      if (msg.t !== "hello") return void ws.close(1008, "schema");
      return this.hello(ws, att, msg);
    }
    switch (msg.t) {
      case "send": return this.send(ws, att, msg);
      case "got":
        if (typeof msg.id !== "string" || !UUID_RE.test(msg.id)) return void ws.close(1008, "schema");
        this.sql.exec("DELETE FROM msgs WHERE id = ?", msg.id);
        return;
      default: return void ws.close(1008, "schema");
    }
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    try { ws.close(code === 1005 || code === 1006 ? 1000 : code); } catch { /* already closed */ }
    await this.schedule();
  }

  private async hello(ws: WebSocket, att: Att, msg: any): Promise<void> {
    if (typeof msg.pub !== "string" || typeof msg.sig !== "string") return void ws.close(1008, "schema");
    const pub = b64decode(msg.pub), sig = b64decode(msg.sig);
    if (!pub || pub.length !== 32 || !sig || sig.length !== 64) return void ws.close(1008, "schema");
    if ((await mailboxId(pub)) !== att.m) return void ws.close(1008, "auth");
    const host = att.host;
    let ok = false;
    try {
      const key = await crypto.subtle.importKey("raw", pub, { name: "Ed25519" }, false, ["verify"]);
      ok = await crypto.subtle.verify({ name: "Ed25519" }, key, sig, new TextEncoder().encode(`true-relay-v1|${att.nonce}|${host}`));
    } catch { ok = false; }
    if (!ok) return void ws.close(1008, "auth");
    const authed = this.ctx.getWebSockets().filter((s) => s !== ws && (s.deserializeAttachment() as Att | null)?.authed).length;
    if (authed >= MAX_SOCKETS) return void ws.close(1008, "too many");
    att.authed = true;
    ws.serializeAttachment(att);
    ws.send(JSON.stringify({ t: "ready" }));
    for (const r of this.sql.exec("SELECT id, frm, blob FROM msgs ORDER BY seq").toArray()) {
      ws.send(JSON.stringify({ t: "msg", from: r.frm, id: r.id, blob: r.blob }));
    }
    await this.schedule();
  }

  private async send(ws: WebSocket, att: Att, msg: any): Promise<void> {
    const { to, id, blob } = msg;
    if (typeof to !== "string" || !MAILBOX_RE.test(to) || typeof id !== "string" || !UUID_RE.test(id) ||
        typeof blob !== "string" || blob.length === 0 || !B64_RE.test(blob)) return void ws.close(1008, "schema");
    if (blob.length > MAX_BLOB) return void ws.close(1009, "too big");
    const now = Date.now();
    if (now - att.win >= 60000) { att.win = now; att.n = 0; }
    if (att.n >= SENDS_PER_MIN) return void ws.send(JSON.stringify({ t: "nack", id, reason: "rate" }));
    att.n++;
    ws.serializeAttachment(att);
    const r = await this.env.MAILBOX.get(this.env.MAILBOX.idFromName(to)).deliver(att.m, id, blob);
    ws.send(JSON.stringify(r.ok ? { t: "ack", id } : { t: "nack", id, reason: r.reason }));
  }

  /** Called by another mailbox's socket (never by clients). Stores, then pushes to live sockets. */
  async deliver(from: string, id: string, blob: string): Promise<{ ok: boolean; reason?: string }> {
    if (blob.length > MAX_BLOB) return { ok: false, reason: "size" };
    if (this.sql.exec("SELECT 1 FROM msgs WHERE id = ?", id).toArray().length) return { ok: true };
    const stat = this.sql.exec("SELECT COUNT(*) AS n, COALESCE(SUM(size), 0) AS b FROM msgs").one() as { n: number; b: number };
    if (stat.n >= MAX_QUEUED) return { ok: false, reason: "full" };
    if (stat.b + blob.length > MAX_BYTES) return { ok: false, reason: "full" };
    this.sql.exec("INSERT INTO msgs (id, frm, blob, size, exp) VALUES (?, ?, ?, ?, ?)", id, from, blob, blob.length, Date.now() + this.ttl);
    const frame = JSON.stringify({ t: "msg", from, id, blob });
    for (const s of this.ctx.getWebSockets()) {
      if ((s.deserializeAttachment() as Att | null)?.authed) { try { s.send(frame); } catch { /* closing */ } }
    }
    await this.schedule();
    return { ok: true };
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    this.sql.exec("DELETE FROM msgs WHERE exp <= ?", now);
    for (const s of this.ctx.getWebSockets()) {
      const a = s.deserializeAttachment() as Att | null;
      if (!a || (!a.authed && now - a.t0 >= this.authMs)) { try { s.close(1008, "auth timeout"); } catch { /* gone */ } }
    }
    await this.schedule();
  }

  /** One alarm: the earlier of the next message expiry and the next unauthenticated-socket deadline. */
  private async schedule(): Promise<void> {
    let next = Infinity;
    const row = this.sql.exec("SELECT MIN(exp) AS e FROM msgs").one() as { e: number | null };
    if (row.e !== null) next = row.e;
    for (const s of this.ctx.getWebSockets()) {
      const a = s.deserializeAttachment() as Att | null;
      if (a && !a.authed) next = Math.min(next, a.t0 + this.authMs);
    }
    if (next === Infinity) await this.ctx.storage.deleteAlarm();
    else await this.ctx.storage.setAlarm(Math.max(next, Date.now() + 1));
  }
}
