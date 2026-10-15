import { SELF, env, runDurableObjectAlarm } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { MAX_BLOB, mailboxId, type Env } from "../src/index";

declare module "cloudflare:test" { interface ProvidedEnv extends Env {} }

const HOST = "relay.test";
const enc = new TextEncoder();
const b64 = (u: Uint8Array) => btoa(String.fromCharCode(...u));
const uuid = () => crypto.randomUUID();

interface Id { pub: Uint8Array; priv: CryptoKey; mid: string }
async function newId(): Promise<Id> {
  const kp = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pub = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey) as ArrayBuffer);
  return { pub, priv: kp.privateKey, mid: await mailboxId(pub) };
}

/** A tiny client: queues every frame it receives, resolves waiters in order. */
class Sock {
  frames: any[] = [];
  closed: { code: number } | null = null;
  private waiters: Array<() => void> = [];
  constructor(readonly ws: WebSocket) {
    ws.addEventListener("message", (e) => { this.frames.push(JSON.parse(e.data as string)); this.poke(); });
    ws.addEventListener("close", (e) => { this.closed = { code: e.code }; this.poke(); });
  }
  private poke() { const w = this.waiters; this.waiters = []; w.forEach((f) => f()); }
  async until<T>(pick: () => T | undefined, ms = 3000): Promise<T> {
    const end = Date.now() + ms;
    for (;;) {
      const v = pick(); if (v !== undefined) return v;
      if (Date.now() > end) throw new Error("timeout; frames=" + JSON.stringify(this.frames.map((f) => f.t)));
      await new Promise<void>((r) => { this.waiters.push(r); setTimeout(r, 50); });
    }
  }
  next(t: string) { return this.until(() => { const i = this.frames.findIndex((f) => f.t === t); return i < 0 ? undefined : this.frames.splice(i, 1)[0]; }); }
  closedWith() { return this.until(() => this.closed ?? undefined); }
  send(o: unknown) { this.ws.send(JSON.stringify(o)); }
}

async function open(mid: string): Promise<{ sock?: Sock; status: number }> {
  const r = await SELF.fetch(`https://${HOST}/v1/connect?m=${mid}`, { headers: { Upgrade: "websocket" } });
  if (r.status !== 101 || !r.webSocket) return { status: r.status };
  r.webSocket.accept();
  return { sock: new Sock(r.webSocket), status: 101 };
}

async function hello(id: Id, sock: Sock, host = HOST) {
  const ch = await sock.next("challenge");
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, id.priv, enc.encode(`true-relay-v1|${ch.nonce}|${host}`)));
  sock.send({ t: "hello", pub: b64(id.pub), sig: b64(sig) });
}

async function connect(id: Id): Promise<Sock> {
  const { sock } = await open(id.mid);
  await hello(id, sock!);
  await sock!.next("ready");
  return sock!;
}

const blobOf = (n = 40) => b64(crypto.getRandomValues(new Uint8Array(n)));

describe("health", () => {
  it("answers ok + version", async () => {
    const r = await SELF.fetch(`https://${HOST}/v1/health`);
    expect(await r.json()).toEqual({ ok: true, version: "1" });
  });
  it("rejects a bad mailbox and a non-websocket connect", async () => {
    expect((await SELF.fetch(`https://${HOST}/v1/connect?m=zz`, { headers: { Upgrade: "websocket" } })).status).toBe(400);
    expect((await SELF.fetch(`https://${HOST}/v1/connect?m=${"a".repeat(32)}`)).status).toBe(426);
  });
});

describe("hello", () => {
  it("good hello binds the socket", async () => {
    const a = await newId();
    const s = await connect(a);
    expect(s.closed).toBeNull();
  });
  it("bad signature closes", async () => {
    const a = await newId(), other = await newId();
    const { sock } = await open(a.mid);
    const ch = await sock!.next("challenge");
    const sig = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, other.priv, enc.encode(`true-relay-v1|${ch.nonce}|${HOST}`)));
    sock!.send({ t: "hello", pub: b64(a.pub), sig: b64(sig) });
    expect((await sock!.closedWith()).code).toBe(1008);
  });
  it("signature over another host closes", async () => {
    const a = await newId();
    const { sock } = await open(a.mid);
    await hello(a, sock!, "evil.example");
    expect((await sock!.closedWith()).code).toBe(1008);
  });
  it("key that is not this mailbox closes", async () => {
    const a = await newId(), b = await newId();
    const { sock } = await open(a.mid);
    await hello(b, sock!);
    expect((await sock!.closedWith()).code).toBe(1008);
  });
  it("send before hello closes", async () => {
    const a = await newId();
    const { sock } = await open(a.mid);
    await sock!.next("challenge");
    sock!.send({ t: "send", to: a.mid, id: uuid(), blob: blobOf() });
    expect((await sock!.closedWith()).code).toBe(1008);
  });
  it("an unauthenticated socket is closed by the alarm", async () => {
    const a = await newId();
    const { sock } = await open(a.mid);
    await sock!.next("challenge");
    await new Promise((r) => setTimeout(r, 400));   // AUTH_TIMEOUT_MS = 300 in the test config
    await runDurableObjectAlarm(env.MAILBOX.get(env.MAILBOX.idFromName(a.mid)));
    expect((await sock!.closedWith()).code).toBe(1008);
  });
  it("the 5th socket is refused", async () => {
    const a = await newId();
    for (let i = 0; i < 4; i++) await connect(a);
    expect((await open(a.mid)).status).toBe(429);
  });
});

describe("delivery", () => {
  it("live delivery, ack, and got deletes", async () => {
    const a = await newId(), b = await newId();
    const sa = await connect(a), sb = await connect(b);
    const id = uuid(), blob = blobOf();
    sa.send({ t: "send", to: b.mid, id, blob });
    expect(await sa.next("ack")).toEqual({ t: "ack", id });
    const m = await sb.next("msg");
    expect(m).toEqual({ t: "msg", from: a.mid, id, blob });
    sb.send({ t: "got", id });
    await new Promise((r) => setTimeout(r, 100));
    const sb2 = await connect(b);              // nothing left to flush
    await new Promise((r) => setTimeout(r, 150));
    expect(sb2.frames.filter((f) => f.t === "msg")).toHaveLength(0);
  });
  it("offline queue, then flush on connect; unacked stays", async () => {
    const a = await newId(), b = await newId();
    const sa = await connect(a);
    const ids = [uuid(), uuid()];
    for (const id of ids) { sa.send({ t: "send", to: b.mid, id, blob: blobOf() }); await sa.next("ack"); }
    const sb = await connect(b);
    expect((await sb.next("msg")).id).toBe(ids[0]);
    expect((await sb.next("msg")).id).toBe(ids[1]);
    sb.ws.close(1000);
    const sb2 = await connect(b);              // never confirmed: delivered again
    expect((await sb2.next("msg")).id).toBe(ids[0]);
  });
  it("a repeated id is acked once, stored once", async () => {
    const a = await newId(), b = await newId();
    const sa = await connect(a);
    const id = uuid();
    sa.send({ t: "send", to: b.mid, id, blob: blobOf() }); await sa.next("ack");
    sa.send({ t: "send", to: b.mid, id, blob: blobOf() }); await sa.next("ack");
    const sb = await connect(b);
    await sb.next("msg");
    await new Promise((r) => setTimeout(r, 150));
    expect(sb.frames.filter((f) => f.t === "msg")).toHaveLength(0);
  });
  it("TTL sweep removes old messages", async () => {
    const a = await newId(), b = await newId();
    const sa = await connect(a);
    sa.send({ t: "send", to: b.mid, id: uuid(), blob: blobOf() }); await sa.next("ack");
    await new Promise((r) => setTimeout(r, 2200));   // TTL_MS = 2000 in the test config
    await runDurableObjectAlarm(env.MAILBOX.get(env.MAILBOX.idFromName(b.mid)));
    const sb = await connect(b);
    await new Promise((r) => setTimeout(r, 150));
    expect(sb.frames.filter((f) => f.t === "msg")).toHaveLength(0);
  });
});

describe("caps", () => {
  it("a blob over 192 KB closes the socket", async () => {
    const a = await newId(), b = await newId();
    const sa = await connect(a);
    sa.send({ t: "send", to: b.mid, id: uuid(), blob: "A".repeat(MAX_BLOB + 4) });
    expect((await sa.closedWith()).code).toBe(1009);
  });
  it("off-schema closes", async () => {
    const a = await newId();
    const sa = await connect(a);
    sa.send({ t: "send", to: "nope", id: "x", blob: "y" });
    expect((await sa.closedWith()).code).toBe(1008);
  });
  it("201st queued message is refused", async () => {
    const b = await newId();
    const stub = env.MAILBOX.get(env.MAILBOX.idFromName(b.mid));
    for (let i = 0; i < 200; i++) expect((await stub.deliver("a".repeat(32), uuid(), "QQ==")).ok).toBe(true);
    expect(await stub.deliver("a".repeat(32), uuid(), "QQ==")).toEqual({ ok: false, reason: "full" });
  });
  it("8 MB cap on queued bytes", async () => {
    const b = await newId();
    const stub = env.MAILBOX.get(env.MAILBOX.idFromName(b.mid));
    const big = "A".repeat(MAX_BLOB);
    let ok = 0;
    for (let i = 0; i < 60; i++) if ((await stub.deliver("a".repeat(32), uuid(), big)).ok) ok++;
    expect(ok).toBe(Math.floor((8 * 1024 * 1024) / MAX_BLOB));
  });
  it("61st send in a minute is nacked for rate", async () => {
    const a = await newId(), b = await newId();
    const sa = await connect(a);
    for (let i = 0; i < 60; i++) sa.send({ t: "send", to: b.mid, id: uuid(), blob: "QQ==" });
    const id = uuid();
    sa.send({ t: "send", to: b.mid, id, blob: "QQ==" });
    const nack = await sa.next("nack");
    expect(nack).toEqual({ t: "nack", id, reason: "rate" });
  });
});
