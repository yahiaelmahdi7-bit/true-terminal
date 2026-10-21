#!/usr/bin/env python3
"""Dev-only mock of True's phone server, so Resources/Remote/* can be opened in a desktop browser at phone size.
MOCK_STATE=normal|empty|offline|pairing (default normal), MOCK_PORT (default 8899). Pair code: 123456. No WebSocket."""
import json, mimetypes, os, pathlib, re, struct, time, zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent / "Resources" / "Remote"
STATE = os.environ.get("MOCK_STATE", "normal")
LONG = "refactor-the-entire-authentication-and-session-middleware-for-the-multi-tenant-gateway"
ROUTES, CONFIRMED = {}, set()

def row(kind, name, status, key, **kw): return dict(kind=kind, id=name, name=name, status=status, statusKey=key, **kw)

def hub():
    if STATE == "empty": return dict(summary="", projects=[])  # matches the Mac: blank when idle
    return dict(summary="1 working · 1 needs you · 1 done", projects=[
        dict(title="true", summary="1 working · 1 needs you", rows=[
            row("seat", "lead-true", "Working", "working", pane="11111111-1111-1111-1111-111111111111", cwd="~/Projects/true", elapsed="12m"),
            row("seat", "helper-1-true", "Needs you", "needsYou", pane="22222222-2222-2222-2222-222222222222", cwd="~/Projects/true/Sources", elapsed="3m"),
            row("seat", "helper-2-true", "Asleep", "asleep", pane="33333333-3333-3333-3333-333333333333", cwd="~/Projects/true"),
            row("background", "builder run-26", "Done", "done", builderId="run-26", acked=False, cwd="~/Projects/true.builders", elapsed="41m")]),
        dict(title="axon", summary="1 failed", rows=[
            row("background", "builder lean-pivot", "Failed", "failed", builderId="lean-pivot", acked=False, elapsed="8m"),
            row("seat", "lead-axon", "Idle", "idle", pane="44444444-4444-4444-4444-444444444444", cwd="~/Projects/axon"),
            row("other", "zsh in Ghostty", "Working", "working", cwd="~/Projects/axon", elapsed="1h 2m")]),
        dict(title="prism", summary="1 working", rows=[
            row("seat", LONG, "Working", "working", pane="55555555-5555-5555-5555-555555555555", cwd="~/Projects/prism/" + LONG + "/packages/core", elapsed="2h 14m")])])

def route(text):
    cand = lambda *p: [dict(value=v, label=l) for v, l in p]
    r = dict(text=text, kind="agentTask", kindLabel="Claude task", project="true", target="newPane", where="New pane",
             model="opus", effort="high", uncertain=["project"], twoChoice=False, dangerous="delete" in text, typedOnly=False, runnable=True)
    c = dict(kind=cand(("agentTask", "Claude task"), ("shellCommand", "Shell command"), ("seat", "Seat")),
             project=cand(("true", "true"), ("axon", "axon"), ("prism", "prism")),
             target=cand(("newPane", "New pane"), ("newTab", "New tab"), ("seat", "Seat lead-true")),
             model=cand(("opus", "opus"), ("sonnet", "sonnet"), ("haiku", "haiku")),
             effort=cand(("low", "low"), ("medium", "medium"), ("high", "high")))
    return r, c

def png(w=64, h=64, rgb=(80, 70, 60)):
    raw = b"".join(b"\0" + bytes(rgb) * w for _ in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body=b"", ctype="application/json"):
        if not isinstance(body, bytes): body = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(body)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0); raw = self.rfile.read(n) if n else b""
        try: return json.loads(raw or b"{}")
        except ValueError: return {}
    def do_GET(self):
        p = self.path.split("?")[0]
        if not p.startswith("/api/"):
            f = ROOT / ("index.html" if p == "/" else p.lstrip("/"))
            if f.is_file() and ROOT in f.resolve().parents:
                return self.send(200, f.read_bytes(), mimetypes.guess_type(f.name)[0] or "application/octet-stream")
            return self.send(404, b"", "text/plain")
        self.api("GET", p)
    def do_POST(self): self.api("POST", self.path.split("?")[0])
    def do_DELETE(self): self.api("DELETE", self.path.split("?")[0])
    def api(self, method, p):
        b = self.body()
        if p == "/pair":
            return self.send(200, dict(token="mock-token")) if b.get("code") == "123456" else self.send(403, dict(error="Wrong code."))
        if STATE == "offline": return self.send(503, dict(error="offline"))
        if STATE == "pairing": return self.send(401, dict(error="unpaired"))
        empty = STATE == "empty"
        if p == "/api/hub": return self.send(200, hub())
        if p == "/api/tabs": return self.send(200, dict(tabs=[]))
        if p.startswith("/api/hub/builder/"):
            if p.endswith("/ack"): return self.send(200, dict(ok=True))
            return self.send(200, dict(name="builder run-26", status="Done", acked=False, canAck=True,
                                       text="Run 26 complete.\n  3 files changed\n  swift test: 41 passed\n" * 6))
        if p == "/api/recent": return self.send(200, dict(items=[] if empty else ["fix the login test in true", "wake helper-2-true", "open axon in a new tab",
                                                                                    "$ git status", "review the last commit in prism", "sleep helper-1-true"]))
        if p == "/api/route":
            r, c = route(b.get("text", "")); rid = "r%d" % len(ROUTES); ROUTES[rid] = (r, c)
            return self.send(200, dict(routeId=rid, route=r, alternatives=["shellCommand"], candidates=c))
        m = re.match(r"/api/route/([^/]+)/slot$", p)
        if m and m.group(1) in ROUTES:
            r, c = ROUTES[m.group(1)]; s, v = b.get("slot"), b.get("value")
            if s not in c or v not in [o["value"] for o in c[s]]: return self.send(400, dict(error="bad"))
            lab = next(o["label"] for o in c[s] if o["value"] == v)
            r[{"kind": "kind", "target": "target"}.get(s, s)] = v
            if s == "kind": r["kindLabel"] = lab
            if s == "target": r["where"] = lab
            if s == "project": r["uncertain"] = []
            return self.send(200, dict(route=r, alternatives=[], candidates=c))
        if p == "/api/run":
            rid = b.get("routeId")
            if rid not in ROUTES: return self.send(404, dict(error="expired"))
            if not b.get("confirm") and rid not in CONFIRMED:
                CONFIRMED.add(rid); return self.send(409, dict(needsConfirm=True, reason="background_builder" if b.get("background") else "dangerous_text"))
            return self.send(200, dict(pane="11111111-1111-1111-1111-111111111111") if not b.get("background") else dict(background="run-27"))
        if p == "/api/shots": return self.send(200, dict(shots=[] if empty else [dict(id="20261009-10%04d-abcd" % i, created="2026-10-09T10:%02d:00Z" % i, kind="screen", w=64, h=64) for i in range(7)]))
        if p.startswith("/api/shots/"): return self.send(200, png(rgb=(60 + 25 * (hash(p) % 6), 70, 80)), "image/png")
        if p == "/api/inbox":
            return self.send(200, dict(items=[] if empty else [dict(id="a" * 16, kind="text", name="Clipboard", preview="npm run build && npm test -- --watch=false", size=44, source="clipboardShare", created=time.time() - 120),
                                                                dict(id="b" * 16, kind="file", name="Quarterly-report-final-v3.pdf", size=1843200)]))
        if p.startswith("/api/inbox/"): return self.send(200, b"npm run build", "text/plain")
        if p in ("/api/drop", "/api/clip"): return self.send(200, dict(ok=True))
        self.send(404, dict(error="not found"))

if __name__ == "__main__":
    port = int(os.environ.get("MOCK_PORT", "8899"))
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
