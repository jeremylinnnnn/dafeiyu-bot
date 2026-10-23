#!/usr/bin/env python3
"""容器级端到端验证：合成 OneBot + 独立数据目录 + 合成凭证。

验证的是"部署形态"这一层，单元测试覆盖不到的接线问题：
  1. 容器内 UID / 凭证文件读取 / 数据卷属主
  2. 冷启动无授权 → 不自动连（fail-closed）
  3. 面板保存连接配置 → 连接 → 开始运行 → run-intent.json 落盘
  4. T2：删除并重建容器 → 自动恢复连接与运行
  5. 服务掉线 → 进入重连 → 服务恢复 → 自动恢复运行
  6. T4：手动暂停 → 重建容器 → 保持停止
  7. 凭证权限过宽 → 明确拒绝

不连真实 QQ、不读真实聊天，凭证内容都是假的。
用法：
  python3 scripts/verify-cloud-container.py --image dafeiyu-backend:test --workdir /tmp/dafeiyu-e2e
  在需要 sudo 的环境里：DOCKER="sudo docker" python3 scripts/verify-cloud-container.py ...
"""
import argparse
import json
import os
import pathlib
import selectors
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

DOCKER = os.environ.get('DOCKER', 'docker').split()
CONTAINER = 'dafeiyu-e2e'
SELF_ID = '10000'
MARKER = '.dafeiyu-synthetic-e2e'
LABEL = 'org.dafeiyu.synthetic-e2e'

failures = []


def run(*args, **kwargs):
    kwargs.setdefault('timeout', 60)
    return subprocess.run(DOCKER + list(args), capture_output=True, text=True, **kwargs)


def check(label, ok, detail=''):
    print(('PASS  ' if ok else 'FAIL  ') + label + (('  | ' + detail) if detail and not ok else ''))
    if not ok:
        failures.append(label + (('  | ' + detail) if detail else ''))


def remove_container():
    existing = run('inspect', '--format', '{{index .Config.Labels "' + LABEL + '"}}', CONTAINER)
    if existing.returncode == 0 and existing.stdout.strip() != 'true':
        raise SystemExit('拒绝删除不是本脚本创建的容器：' + CONTAINER)
    run('rm', '-f', CONTAINER)


def start_container(image, root, extra=()):
    remove_container()
    args = ['run', '-d', '--name', CONTAINER,
            '--label', LABEL + '=true',
            # host 网络：容器里的后端要连 127.0.0.1:3001，验证脚本也要连它的控制口。
            '--network', 'host',
            '-v', f'{root}/data:/data',
            '-v', f'{root}/secrets:/run/secrets:ro',
            '-e', 'DAFEIYU_ONEBOT_TOKEN_FILE=/run/secrets/onebot-token',
            '-e', 'DAFEIYU_DEEPSEEK_KEY_FILE=/run/secrets/deepseek-key',
            *extra, image]
    result = run(*args)
    if result.returncode != 0:
        raise SystemExit('容器启动失败：' + result.stderr)


def logs():
    result = run('logs', CONTAINER)
    return (result.stdout or '') + (result.stderr or '')


def control_url(timeout=30):
    limit = time.time() + timeout
    while time.time() < limit:
        for line in logs().splitlines():
            if line.startswith('QQ_CONTROL_URL='):
                return line.split('=', 1)[1].strip()
        time.sleep(0.3)
    return None


def split_url(url):
    rest = url.split('://', 1)[1]
    port = rest.split('/', 1)[0].split(':')[1]
    token = url.split('#', 1)[1]
    return port, token


def status(port, token):
    request = urllib.request.Request(f'http://127.0.0.1:{port}/api/status',
                                     headers={'x-qq-control': token, 'origin': f'http://127.0.0.1:{port}'})
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read())


def action(port, token, payload, expect_ok=True):
    """每次写操作都重新取 revision：保存配置会让 revision 轮换。"""
    payload = dict(payload, configurationRevision=status(port, token)['configurationRevision'])
    body = json.dumps(payload).encode()
    request = urllib.request.Request(f'http://127.0.0.1:{port}/api/action', data=body, method='POST',
                                     headers={'x-qq-control': token, 'origin': f'http://127.0.0.1:{port}',
                                              'content-type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.loads(response.read())
    except urllib.error.HTTPError as error:
        result = {'error': f'HTTP {error.code}'}
    if expect_ok and result.get('error'):
        raise SystemExit(f'操作 {payload.get("action")} 失败：{result["error"]}')
    return result


def read_text(path):
    """数据目录里的文件是 0600 + 属主 10001，验证脚本以普通用户跑时读不到。"""
    try:
        return path.read_text()
    except PermissionError:
        return subprocess.run(['sudo', 'cat', str(path)], capture_output=True, text=True).stdout


def wait_until(fn, timeout, interval=0.4):
    limit = time.time() + timeout
    while time.time() < limit:
        value = fn()
        if value:
            return value
        time.sleep(interval)
    return None


def start_fixture(port, control):
    process = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).with_name('onebot-e2e-fixture.py')),
                                str(port), str(control)],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    with selectors.DefaultSelector() as ready:
        ready.register(process.stdout, selectors.EVENT_READ)
        if not ready.select(timeout=10):
            process.kill()
            process.wait(timeout=5)
            raise SystemExit('合成服务启动超时')
        line = process.stdout.readline().strip()
    if not line.startswith('listening on 127.0.0.1:'):
        process.kill()
        process.wait(timeout=5)
        raise SystemExit('合成服务启动失败：' + line)
    return process, int(line.rsplit(':', 1)[1])


def chmod(path, mode):
    if os.geteuid() == 0:
        os.chmod(path, mode)
    else:
        subprocess.run(['sudo', 'chmod', format(mode, 'o'), str(path)], check=True)


def chown(path, uid):
    if os.geteuid() == 0:
        os.chown(path, uid, uid)
    else:
        subprocess.run(['sudo', 'chown', f'{uid}:{uid}', str(path)], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--image', required=True)
    parser.add_argument('--workdir', default='/tmp/dafeiyu-e2e')
    args = parser.parse_args()

    root = pathlib.Path(args.workdir).resolve()
    if root.exists() and any(root.iterdir()) and not (root / MARKER).is_file():
        raise SystemExit('拒绝清理未标记的目录；请指定新的独立 --workdir')
    # 上一轮的数据目录属主是容器用户 10001，普通用户删不掉里面的文件。
    shutil.rmtree(root, ignore_errors=True)
    if root.exists():
        subprocess.run(['sudo', 'rm', '-rf', str(root)], check=True)
    (root / 'data').mkdir(parents=True)
    (root / 'secrets').mkdir(parents=True)
    (root / 'control').mkdir(parents=True)
    (root / MARKER).write_text('synthetic data only\n')
    fixture, fixture_port = start_fixture(0, root / 'control')

    try:
        (root / 'secrets' / 'onebot-token').write_text('synthetic-onebot-token\n')
        (root / 'secrets' / 'deepseek-key').write_text('synthetic-deepseek-key\n')
        for name in ('onebot-token', 'deepseek-key'):
            os.chmod(root / 'secrets' / name, 0o400)
        # 数据目录与凭证目录的属主必须是容器内的运行用户（10001），
        # 否则后端读不到凭证、也写不进 run-intent.json。
        for folder in ('data', 'secrets'):
            target = str(root / folder)
            if os.geteuid() == 0:
                for parent, directories, files in os.walk(target):
                    for path in [parent, *(os.path.join(parent, name) for name in directories + files)]:
                        os.chown(path, 10001, 10001)
            else:
                subprocess.run(['sudo', 'chown', '-R', '10001:10001', target], check=True)

        print('===== 1. 容器内运行身份 =====')
        identity = run('run', '--rm', '--entrypoint', 'id', args.image).stdout.strip()
        check('容器以 uid 10001 运行', 'uid=10001' in identity, identity)

        print('\n===== 2. 首次启动：无运行意图时不自动连接 =====')
        start_container(args.image, root)
        url = control_url()
        check('控制页地址已公布', url is not None)
        if url is None:
            raise SystemExit('控制页地址未公布：' + logs()[-500:])
        port, token = split_url(url)
        mounts = run('inspect', '--format',
                     '{{range .Mounts}}{{if eq .Destination "/run/secrets"}}{{.RW}}{{end}}{{end}}', CONTAINER)
        check('凭证目录只读挂载', mounts.stdout.strip() == 'false')
        time.sleep(2)
        state = status(port, token)
        check('未自动连接', state['connected'] is False, str(state['status']))
        check('未自动运行', state['running'] is False, str(state['status']))

        print('\n===== 3. 保存连接配置 → 连接 → 开始运行 =====')
        action(port, token, {'action': 'saveConnection', 'endpoint': f'ws://127.0.0.1:{fixture_port}',
                             'expectedSelfID': SELF_ID})
        action(port, token, {'action': 'connect'})
        state = wait_until(lambda: (lambda s: s if s['connected'] else None)(status(port, token)), 20)
        check('已连上合成服务', state is not None, logs()[-300:])
        # 开始回复前必须有一个"已通过联系人列表核对"的目标，这是刻意的防误发设计。
        contacts = (state or {}).get('contacts') or []
        check('已取到联系人列表', len(contacts) > 0, str(contacts))
        if contacts:
            key = contacts[0]['key']
            action(port, token, {'action': 'add', 'target': key})
            # add 只把目标加进名单（enabled 默认 false），要再 save 一次才算启用。
            action(port, token, {'action': 'save', 'enabled': [key]})
        action(port, token, {'action': 'start', 'durationMinutes': 120})
        state = wait_until(lambda: (lambda s: s if s['running'] else None)(status(port, token)), 20)
        check('已开始运行', state is not None, logs()[-300:])
        intent = root / 'data' / 'run-intent.json'
        check('run-intent.json 已落盘', intent.exists())
        if intent.exists():
            text = read_text(intent)
            check('落盘内容为已授权', json.loads(text).get('enabled') is True, text)

        print('\n===== 4. T2：删除并重建容器后自动恢复 =====')
        remove_container()
        start_container(args.image, root)
        url = control_url()
        port, token = split_url(url)
        state = wait_until(lambda: (lambda s: s if s['connected'] and s['running'] else None)(status(port, token)), 45)
        check('重建后自动恢复连接与运行', state is not None,
              (logs()[-400:] if state is None else ''))

        print('\n===== 5. 服务掉线 → 重连 → 恢复运行 =====')
        (root / 'control' / 'drop').write_text('1')
        state = wait_until(lambda: (lambda s: s if not s['connected'] else None)(status(port, token)), 20)
        check('掉线后已断开', state is not None)
        state = wait_until(lambda: (lambda s: s if '重连' in s['status'] else None)(status(port, token)), 20)
        check('已进入自动重连', state is not None, logs()[-300:])
        fixture.terminate()
        fixture.wait(timeout=10)
        fixture, _ = start_fixture(fixture_port, root / 'control')
        state = wait_until(lambda: (lambda s: s if s['connected'] and s['running'] else None)(status(port, token)), 60)
        check('服务恢复后自动重连并恢复运行', state is not None,
              (logs()[-400:] if state is None else ''))

        print('\n===== 6. T4：手动暂停 → 重建容器 → 保持停止 =====')
        action(port, token, {'action': 'pause'})
        check('手动暂停已停止运行', status(port, token)['running'] is False)
        check('停止授权已落盘', json.loads(read_text(intent)).get('enabled') is False)
        remove_container()
        start_container(args.image, root)
        url = control_url()
        if url is None:
            raise SystemExit('暂停后重建未启动控制页')
        port, token = split_url(url)
        time.sleep(2)
        state = status(port, token)
        check('暂停后重建不自动连接或回复', not state['connected'] and not state['running'])

        print('\n===== 7. 凭证权限过宽时拒绝启动 =====')
        remove_container()
        chmod(root / 'secrets' / 'onebot-token', 0o644)
        start_container(args.image, root)
        time.sleep(5)
        text = logs()
        check('权限 644 被明确拒绝', '权限 644 过宽' in text, text[-300:])

        print('\n===== 8. 凭证属主错误时拒绝启动 =====')
        remove_container()
        credential = root / 'secrets' / 'onebot-token'
        chmod(credential, 0o400)
        chown(credential, 0)
        start_container(args.image, root)
        time.sleep(2)
        text = logs()
        check('属主 UID 0 被明确拒绝', '属主 uid=0 与运行用户 uid=10001 不一致' in text, text[-300:])
    finally:
        remove_container()
        fixture.terminate()
        try:
            fixture.wait(timeout=5)
        except subprocess.TimeoutExpired:
            fixture.kill()

    print()
    if failures:
        print(f'{len(failures)} 项未通过：')
        for item in failures:
            print('  - ' + item)
        sys.exit(1)
    print('全部通过')


if __name__ == '__main__':
    main()
