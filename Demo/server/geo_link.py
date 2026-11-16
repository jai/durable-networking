#!/usr/bin/env python3
"""A geostationary satellite's round trip (about 600 ms) between the demo app and everything it reaches.

Two ways in, both delaying every byte by half the round trip each way:

  --socks PORT                 a SOCKS5 proxy for the app's direct requests. A new connection costs --setup-rtts
                               round trips before it carries data (default 2: TCP, then TLS 1.3, which a real https
                               request pays; the demo server itself is plain http). DNS is taken as cached.
  --forward PORT:HOST:TARGET   a plain TCP forward, for the satmux carriers to the relay: one round trip to connect.

What it leaves out, so the direct path's cost is if anything understated: packet loss, TCP slow start and the link's
bandwidth. The relay's own requests (it fetches on the ground) do not pass through here.

  geo_link.py --rtt-ms 600 --socks 1081 --forward 8445:127.0.0.1:8444

Standard library only.
"""

from __future__ import annotations

import argparse
import asyncio
import socket
import struct
import time

RTT = 0.6
SETUP_RTTS = 2


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    """Copies reader to writer, each chunk arriving half a round trip after it was read, in order."""
    queue: asyncio.Queue[tuple[float, bytes]] = asyncio.Queue()

    async def deliver() -> None:
        while True:
            due, chunk = await queue.get()
            wait = due - time.monotonic()
            if wait > 0:
                await asyncio.sleep(wait)
            if not chunk:
                try:
                    writer.write_eof()
                except (OSError, RuntimeError):
                    pass
                return
            writer.write(chunk)
            await writer.drain()

    delivery = asyncio.create_task(deliver())
    try:
        while True:
            chunk = await reader.read(65536)
            queue.put_nowait((time.monotonic() + RTT / 2, chunk))
            if not chunk:
                break
        await delivery
    except (OSError, asyncio.IncompleteReadError):
        delivery.cancel()
    finally:
        writer.close()


async def splice(
    a: tuple[asyncio.StreamReader, asyncio.StreamWriter], b: tuple[asyncio.StreamReader, asyncio.StreamWriter]
) -> None:
    await asyncio.gather(pipe(a[0], b[1]), pipe(b[0], a[1]), return_exceptions=True)


def forwarder(host: str, port: int):
    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        await asyncio.sleep(RTT)  # TCP's handshake over the link
        try:
            target = await asyncio.open_connection(host, port)
        except OSError:
            writer.close()
            return
        target[1].get_extra_info("socket").setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        await splice((reader, writer), target)

    return handle


async def socks(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        _, methods = await reader.readexactly(2)
        await reader.readexactly(methods)
        writer.write(b"\x05\x00")
        _, command, _, kind = await reader.readexactly(4)
        if kind == 1:
            host = socket.inet_ntoa(await reader.readexactly(4))
        elif kind == 3:
            host = (await reader.readexactly((await reader.readexactly(1))[0])).decode()
        elif kind == 4:
            host = socket.inet_ntop(socket.AF_INET6, await reader.readexactly(16))
        else:
            raise ValueError(kind)
        (port,) = struct.unpack("!H", await reader.readexactly(2))
        if command != 1:
            raise ValueError(command)
        await asyncio.sleep(RTT * SETUP_RTTS)  # the handshakes over the link
        target = await asyncio.open_connection(host, port)
    except (OSError, ValueError, asyncio.IncompleteReadError):
        writer.close()
        return
    writer.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
    await writer.drain()
    await splice((reader, writer), target)


async def main() -> None:
    global RTT, SETUP_RTTS
    parser = argparse.ArgumentParser()
    parser.add_argument("--rtt-ms", type=int, default=600)
    parser.add_argument("--setup-rtts", type=int, default=2)
    parser.add_argument("--socks", type=int)
    parser.add_argument("--forward", action="append", default=[])
    args = parser.parse_args()
    RTT = args.rtt_ms / 1000
    SETUP_RTTS = args.setup_rtts
    servers = []
    if args.socks:
        servers.append(await asyncio.start_server(socks, "127.0.0.1", args.socks))
        print(f"geo link: socks5 on 127.0.0.1:{args.socks}, {args.rtt_ms} ms round trip", flush=True)
    for spec in args.forward:
        listen, host, port = spec.split(":")
        servers.append(await asyncio.start_server(forwarder(host, int(port)), "127.0.0.1", int(listen)))
        print(f"geo link: 127.0.0.1:{listen} -> {host}:{port}, {args.rtt_ms} ms round trip", flush=True)
    await asyncio.gather(*(server.serve_forever() for server in servers))


if __name__ == "__main__":
    asyncio.run(main())
