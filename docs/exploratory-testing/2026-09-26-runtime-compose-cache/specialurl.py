# Replay: POST invalidation for request targets containing characters that
# are meaningful to the Varnish ban-expression parser.
import socket, subprocess
def raw(req):
    s = socket.create_connection(("127.0.0.1", 18580)); s.sendall(req.encode("latin1")); d = b""
    while (c := s.recv(65536)): d += c
    return " ".join(l for l in d.decode(errors="replace").split("\r\n") if l.startswith("HTTP") or l.split(":")[0].lower() in ("x-cache", "x-origin-n"))
for u in ['/plain', '/q"x', '/b\\x', "/sq'x", '/sp%20x', '/amp?a=1&&b=2', '/tilde~x', '/brace{x}']:
    g = f"GET {u} HTTP/1.1\r\nHost: app.test\r\nConnection: close\r\n\r\n"
    first = raw(g); raw(g)
    post = raw(f"POST {u} HTTP/1.1\r\nHost: app.test\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    print(f"{u:16} GET1[{first}]  POST[{post}]  GET-after-POST[{raw(g)}]")
