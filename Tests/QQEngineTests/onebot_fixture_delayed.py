"""Synthetic OneBot whose port opens only after a delay.

Why: the reconnect path can only be exercised if the first connect() really fails.
This fixture reserves a port, prints it, stays closed for `delay` seconds, then
binds the same port and answers the four handshake actions.

Loopback only. Synthetic identities. Records nothing about real accounts.
"""
import base64
import hashlib
import pathlib
import runpy
import select
import socket
import sys
import time

delay = float(sys.argv[1])
# 第二个参数：握手再拖多久。用来制造"connect() 正在等待，用户此刻点了暂停"的窗口。
handshake_delay = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
transport = runpy.run_path(str(pathlib.Path(__file__).parents[2] / 'scripts/test-onebot-transport.py'))
exact, receive, send = (transport[name] for name in ('exact', 'receive', 'send'))

# Reserve a free port, then let it go so the first connect() is refused.
probe = socket.socket()
probe.bind(('127.0.0.1', 0))
port = probe.getsockname()[1]
probe.close()
print(port, flush=True)

time.sleep(delay)

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', port))
server.listen(1)
server.settimeout(30)
conn, _ = server.accept()
with conn:
    conn.settimeout(30)
    header = b''
    while b'\r\n\r\n' not in header:
        header += exact(conn, 1)
    fields = dict(line.split(': ', 1) for line in header.decode().split('\r\n')[1:] if ': ' in line)
    fields = {key.lower(): value for key, value in fields.items()}
    assert fields['authorization'] == 'Bearer synthetic-test-token'
    # 拖住握手：此刻客户端的 connect() 正挂起等响应。
    if handshake_delay > 0:
        time.sleep(handshake_delay)
    accept = base64.b64encode(hashlib.sha1(
        (fields['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    conn.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                  'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            if not select.select([conn], [], [], 0.2)[0]:
                continue
            request = receive(conn)
        except (socket.timeout, EOFError, ValueError, OSError):
            break
        action = request['action']
        data = {'get_login_info': {'user_id': 12345},
                'get_status': {'online': True, 'good': True},
                'get_friend_list': [{'user_id': 54321, 'nickname': 'late fixture'}],
                'get_group_list': []}.get(action)
        if data is None:
            raise AssertionError('unexpected action: ' + action)
        send(conn, {'status': 'ok', 'retcode': 0, 'data': data, 'echo': request['echo']})
