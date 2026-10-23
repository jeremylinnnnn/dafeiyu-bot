"""合成 OneBot v11 服务：供容器级验证使用。

与 Tests/QQEngineTests/onebot_fixture.py 的区别：
- 固定端口、可反复接受连接（单元测试那份是一次性的、端口随机）；
- 不依赖 Swift 测试进程，可以被容器里的后端当成本机 NapCat 使用；
- 通过控制目录里的 `drop` 文件模拟"NapCat 掉线"。

身份全是合成的，不连真实 QQ，不读取任何真实聊天。
用法：python3 onebot-e2e-fixture.py <端口> <控制目录>
"""
import base64
import hashlib
import json
import pathlib
import select
import socket
import struct
import sys
import time

SELF_ID = 10000
OWNER = 20001
GROUP = 99999


def exact(conn, count):
    out = b''
    while len(out) < count:
        chunk = conn.recv(count - len(out))
        if not chunk:
            raise EOFError()
        out += chunk
    return out


def receive(conn):
    _, second = exact(conn, 2)
    size = second & 127
    if size == 126:
        size = struct.unpack('!H', exact(conn, 2))[0]
    elif size == 127:
        size = struct.unpack('!Q', exact(conn, 8))[0]
    if size >= 4_100_000:
        raise ValueError('frame too large')
    mask = exact(conn, 4) if second & 128 else b'\0' * 4
    raw = exact(conn, size)
    return json.loads(bytes(b ^ mask[i % 4] for i, b in enumerate(raw)))


def send(conn, value):
    data = json.dumps(value).encode()
    header = bytes([0x81, len(data)]) if len(data) < 126 else b'\x81\x7e' + struct.pack('!H', len(data))
    conn.sendall(header + data)


def answer(action):
    if action == 'get_login_info':
        return {'user_id': SELF_ID, 'nickname': 'synthetic'}
    if action == 'get_status':
        return {'online': True, 'good': True}
    if action == 'get_friend_list':
        return [{'user_id': OWNER, 'nickname': 'synthetic owner'}]
    if action == 'get_group_list':
        return [{'group_id': GROUP, 'group_name': 'synthetic group'}]
    if action in ('send_private_msg', 'send_group_msg'):
        return {'message_id': 1}
    if action == 'get_msg':
        return {'message_id': -1, 'message': []}
    # 其余动作一律成功返回空对象：验证关注的是连接与运行状态，不是具体动作语义。
    return {}


def serve_one(conn, control, index):
    header = b''
    while b'\r\n\r\n' not in header:
        header += exact(conn, 1)
    fields = dict(line.split(': ', 1) for line in header.decode().split('\r\n')[1:] if ': ' in line)
    fields = {key.lower(): value for key, value in fields.items()}
    if fields.get('authorization') != 'Bearer synthetic-onebot-token':
        conn.sendall(b'HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n')
        return
    accept = base64.b64encode(hashlib.sha1(
        (fields['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
    conn.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                  'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
    print(f'[{index}] connected', flush=True)
    while True:
        # 掉线模拟：出现 drop 文件就断开，后端应当判定为网络故障并进入重连。
        drop = control / 'drop'
        if drop.exists():
            drop.unlink()
            print(f'[{index}] dropping connection on request', flush=True)
            return
        if not select.select([conn], [], [], 0.2)[0]:
            continue
        try:
            request = receive(conn)
        except (EOFError, ValueError, OSError):
            print(f'[{index}] client closed', flush=True)
            return
        action = request.get('action', '')
        try:
            data = answer(action)
        except Exception as error:                     # noqa: BLE001 - 合成服务，任何异常都回错
            send(conn, {'status': 'failed', 'retcode': 1400, 'data': None,
                        'echo': request.get('echo'), 'message': str(error)})
            continue
        send(conn, {'status': 'ok', 'retcode': 0, 'data': data, 'echo': request.get('echo')})


def main():
    port = int(sys.argv[1])
    control = pathlib.Path(sys.argv[2])
    control.mkdir(parents=True, exist_ok=True)
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('127.0.0.1', port))
    port = server.getsockname()[1]
    server.listen(4)
    server.settimeout(0.5)
    print(f'listening on 127.0.0.1:{port}', flush=True)
    index = 0
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        try:
            conn, _ = server.accept()
        except socket.timeout:
            continue
        index += 1
        with conn:
            conn.settimeout(30)
            try:
                serve_one(conn, control, index)
            except (EOFError, OSError, KeyError) as error:
                print(f'[{index}] ended: {error!r}', flush=True)


if __name__ == '__main__':
    main()
