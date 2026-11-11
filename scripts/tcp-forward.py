#!/usr/bin/env python3
"""Tiny TCP forwarder for scripts/test-two-home.sh: listen on <bind>:<port>, relay to 127.0.0.1:<target>.
Some Macs only let certain interpreters accept on the tailnet address; this runs under the system python3 so Steward can stay on loopback."""
import asyncio, sys

async def pipe(r, w):
    try:
        while data := await r.read(65536):
            w.write(data); await w.drain()
    except OSError:
        pass
    finally:
        w.close()

async def handle(r, w, target):
    try:
        tr, tw = await asyncio.open_connection("127.0.0.1", target)
    except OSError:
        w.close(); return
    await asyncio.gather(pipe(r, tw), pipe(tr, w))

async def main(bind, port, target):
    server = await asyncio.start_server(lambda r, w: handle(r, w, target), bind, port)
    async with server:
        await server.serve_forever()

asyncio.run(main(sys.argv[1], int(sys.argv[2]), int(sys.argv[3])))
