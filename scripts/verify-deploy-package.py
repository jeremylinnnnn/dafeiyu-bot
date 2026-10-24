#!/usr/bin/env python3
"""部署包级合成验证：交付形态 + 升级/回滚演练。

与 verify-cloud-container.py 的分工：那个脚本验证「容器内行为」，
本脚本验证「交付包」——包完整性、标签匹配、运维入口，以及
升级保留数据、暂停不被覆盖、旧版本可恢复这三条验收标准。

全部使用合成身份与假凭证，不连真实 QQ，不调用真实模型。
镜像本身在包里（docker load 导入），NapCat 不参与（compose 只起 backend）。

用法：
  python3 scripts/verify-deploy-package.py \
      --package /tmp/pkg-a --upgrade-package /tmp/pkg-b --workdir /tmp/dafeiyu-pkg-e2e
  需要 sudo（chown 10001）与 docker；DOCKER="sudo docker" 亦可。
"""
import argparse
import hashlib
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
MARKER = '.dafeiyu-package-rehearsal'
BACKEND_CONTAINER = 'dafeiyu-backend'
SELF_ID = '10000'

failures = []


def run(args, cwd=None, timeout=300, capture=True):
    return subprocess.run(args, cwd=cwd, capture_output=capture, text=True, timeout=timeout)


def docker(*args, **kwargs):
    return run(DOCKER + list(args), **kwargs)


def check(label, ok, detail=''):
    print(('PASS  ' if ok else 'FAIL  ') + label + (('  | ' + detail) if detail and not ok else ''))
    if not ok:
        failures.append(label + (('  | ' + detail) if detail else ''))


# ---------- 包静态校验 ----------

PACKAGE_FILES = ('VERSION.txt', 'SHA256SUMS', 'backend-image.tar.gz', 'docker-compose.yml',
                 'docker-compose.credentials.yml', 'qq-container-entrypoint.sh',
                 'init-qq-config.py', 'SERVER_README.md',
                 'ops/init-check.sh', 'ops/status.sh', 'ops/backup.sh',
                 'ops/restore.sh', 'ops/upgrade.sh', 'ops/rollback.sh')


def static_checks(pkg: pathlib.Path):
    label = f'[{pkg.name}] '
    for rel in PACKAGE_FILES:
        check(label + f'文件存在 {rel}', (pkg / rel).is_file())
    for rel in ('data', 'config', 'backups'):
        check(label + f'目录存在 {rel}/', (pkg / rel).is_dir())

    # SHA256SUMS 全量校验
    result = run(['sha256sum', '--quiet', '-c', 'SHA256SUMS'], cwd=pkg)
    check(label + 'SHA256SUMS 全部通过', result.returncode == 0, result.stdout[-300:] + result.stderr[-300:])

    version = {}
    for line in (pkg / 'VERSION.txt').read_text().splitlines():
        if '=' in line and not line.startswith((' ', '校验', '加载', '该包')):
            key, _, value = line.partition('=')
            version[key.strip()] = value.strip()
    for field in ('package_image', 'image_id', 'platform', 'created_utc'):
        check(label + f'VERSION.txt 有 {field}', bool(version.get(field)))
    tag = version.get('package_image', '').partition(':')[2]
    check(label + 'VERSION.txt 标签与 compose 一致', tag == backend_tag(pkg), f'{tag} vs {backend_tag(pkg)}')

    compose_text = (pkg / 'docker-compose.yml').read_text()
    check(label + 'NapCat 摘要固定', 'mlikiowa/napcat-docker@sha256:' in compose_text)
    check(label + '数据目录环境变量在位', 'DAFEIYU_DATA_DIR: /data' in compose_text)

    result = docker('compose', '-f', 'docker-compose.yml', '-f', 'docker-compose.credentials.yml',
                    'config', '--quiet', cwd=pkg)
    check(label + 'compose（含 credentials 叠加）可解析', result.returncode == 0, result.stderr[-300:])

    for sh in ('ops/init-check.sh', 'ops/upgrade.sh', 'ops/rollback.sh', 'ops/backup.sh',
               'ops/restore.sh', 'ops/status.sh', 'qq-container-entrypoint.sh'):
        check(label + f'bash 语法 {sh}', run(['bash', '-n', str(pkg / sh)]).returncode == 0)
    return version


def backend_tag(pkg: pathlib.Path) -> str:
    for line in (pkg / 'docker-compose.yml').read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith('image:') and 'dafeiyu-backend:' in stripped:
            return stripped.partition('dafeiyu-backend:')[2].strip()
    return ''


# ---------- 面板 API（与 verify-cloud-container.py 同一约定） ----------

def logs():
    result = docker('logs', BACKEND_CONTAINER)
    return (result.stdout or '') + (result.stderr or '')


def control_url(timeout=60):
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


def sudo_chown(path, uid, recursive=True):
    args = ['sudo', 'chown'] + (['-R'] if recursive else []) + [f'{uid}:{uid}', str(path)]
    subprocess.run(args, check=True)


def sudo_chmod(path, mode):
    subprocess.run(['sudo', 'chmod', format(mode, 'o'), str(path)], check=True)


def intent_state(deploy: pathlib.Path):
    text = subprocess.run(['sudo', 'cat', str(deploy / 'data' / 'run-intent.json')],
                          capture_output=True, text=True, check=True).stdout
    return json.loads(text)


def tree_hashes(root: pathlib.Path):
    """data/ 里的文件属主 10001、权限 0600，用 sudo cat 读取后哈希。"""
    hashes = {}
    for path in sorted(root.rglob('*')):
        if path.is_file():
            data = subprocess.run(['sudo', 'cat', str(path)], capture_output=True, check=True).stdout
            hashes[str(path.relative_to(root))] = hashlib.sha256(data).hexdigest()
    return hashes


# ---------- 主流程 ----------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--package', required=True, help='主部署包目录')
    parser.add_argument('--upgrade-package', help='演练用升级包目录（标签须与主包不同）')
    parser.add_argument('--workdir', default='/tmp/dafeiyu-pkg-e2e')
    args = parser.parse_args()

    main_pkg = pathlib.Path(args.package).resolve()
    upgrade_pkg = pathlib.Path(args.upgrade_package).resolve() if args.upgrade_package else None
    root = pathlib.Path(args.workdir).resolve()

    if upgrade_pkg and backend_tag(upgrade_pkg) == backend_tag(main_pkg):
        raise SystemExit('升级包与主包标签相同，无法演练升级')

    # 防呆：不碰已存在的同名容器（可能是用户生产环境）
    existing = docker('ps', '-a', '--filter', f'name=^{BACKEND_CONTAINER}$', '--format', '{{.ID}}')
    if existing.stdout.strip():
        raise SystemExit(f'已存在名为 {BACKEND_CONTAINER} 的容器，拒绝演练；请先清理（可能是生产容器）')

    if root.exists() and any(root.iterdir()) and not (root / MARKER).is_file():
        raise SystemExit('拒绝清理未标记的目录；请指定新的独立 --workdir')
    shutil.rmtree(root, ignore_errors=True)
    if root.exists():
        subprocess.run(['sudo', 'rm', '-rf', str(root)], check=True)
    root.mkdir(parents=True)
    (root / MARKER).write_text('synthetic rehearsal only\n')
    (root / 'control').mkdir()

    print('===== A. 静态校验 =====')
    static_checks(main_pkg)
    if upgrade_pkg:
        static_checks(upgrade_pkg)

    print('\n===== B. 模拟用户：解包、加载镜像、初始化 =====')
    deploy = root / 'deploy'
    shutil.copytree(main_pkg, deploy)
    print('（解包副本的 SHA256 已随静态校验覆盖源包；副本直接用于演练）')

    result = docker('load', '-i', str(main_pkg / 'backend-image.tar.gz'))
    check('backend-image.tar.gz 可被 docker load', result.returncode == 0, result.stderr[-300:])
    main_tag = backend_tag(main_pkg)
    platform = docker('image', 'inspect', f'dafeiyu-backend:{main_tag}',
                      '--format', '{{.Os}}/{{.Architecture}}').stdout.strip()
    print(f'镜像平台：{platform}（演练镜像，与交付平台可能不同，包内 VERSION.txt 为准）')

    for name in ('onebot-token', 'deepseek-key'):
        (deploy / 'secrets').mkdir(exist_ok=True)
        (deploy / 'secrets' / name).write_text(f'synthetic-{name}\n')
        sudo_chmod(deploy / 'secrets' / name, 0o400)
    sudo_chown(deploy / 'data', 10001)
    sudo_chown(deploy / 'secrets', 10001)
    # 与 SERVER_README 一致：secrets/ 是 0700、属主 10001。
    # 这是回归场：运维脚本若把「读不到」当成「不存在」，凭证覆盖会被
    # 静默跳过，run-intent 落盘检查会当场失败。
    sudo_chmod(deploy / 'secrets', 0o700)
    # 合成私人配置（写入演练目录，token 是随机合成值）
    result = run([sys.executable, 'init-qq-config.py', '--directory', './config'], cwd=deploy)
    check('init-qq-config.py 在部署目录生成私人配置', result.returncode == 0, result.stderr[-200:])

    result = run(['bash', 'ops/init-check.sh'], cwd=deploy)
    check('ops/init-check.sh 全部通过', result.returncode == 0, result.stdout[-800:])
    if result.returncode != 0:
        raise SystemExit('init-check 未通过，停止演练')

    print('\n===== C. 运行时演练：授权 → 暂停 =====')
    fixture, fixture_port = start_fixture(0, root / 'control')
    compose_args = ['compose', '-f', 'docker-compose.yml', '-f', 'docker-compose.credentials.yml']
    created_volume = None
    try:
        result = docker(*compose_args, 'up', '-d', '--no-deps', 'backend', cwd=deploy)
        check('compose 起后端（--no-deps，不经 NapCat）', result.returncode == 0, result.stderr[-400:])

        url = control_url()
        check('控制页地址已公布', url is not None)
        if url is None:
            raise SystemExit('未取到控制页：' + logs()[-500:])
        port, token = split_url(url)

        action(port, token, {'action': 'saveConnection', 'endpoint': f'ws://127.0.0.1:{fixture_port}',
                             'expectedSelfID': SELF_ID})
        action(port, token, {'action': 'connect'})
        state = wait_until(lambda: (lambda s: s if s['connected'] else None)(status(port, token)), 30)
        check('已连上合成服务', state is not None, logs()[-300:])
        contacts = (state or {}).get('contacts') or []
        if contacts:
            key = contacts[0]['key']
            action(port, token, {'action': 'add', 'target': key})
            action(port, token, {'action': 'save', 'enabled': [key]})
        action(port, token, {'action': 'start', 'durationMinutes': 120})
        state = wait_until(lambda: (lambda s: s if s['running'] else None)(status(port, token)), 30)
        check('已开始运行', state is not None, logs()[-300:])
        check('run-intent 已授权落盘', intent_state(deploy).get('enabled') is True)

        action(port, token, {'action': 'pause'})
        check('手动暂停已停止', status(port, token)['running'] is False)
        check('run-intent 已撤销落盘', intent_state(deploy).get('enabled') is False)
        result = run(['bash', 'ops/status.sh'], cwd=deploy)
        check('ops/status.sh 可运行且不回显控制 URL', result.returncode == 0
              and 'QQ_CONTROL_URL' not in result.stdout,
              result.stderr[-200:] if result.returncode else 'stdout 含 QQ_CONTROL_URL')
        time.sleep(2)
        snap1 = tree_hashes(deploy / 'data')

        if upgrade_pkg:
            print('\n===== D. 升级演练 =====')
            new_tag = backend_tag(upgrade_pkg)
            result = run(['bash', 'ops/upgrade.sh', str(upgrade_pkg)], cwd=deploy, timeout=900)
            check('ops/upgrade.sh 成功', result.returncode == 0,
                  (result.stdout[-500:] + result.stderr[-500:]) if result.returncode else '')
            if result.returncode != 0:
                raise SystemExit('升级演练失败')
            check('compose 标签已切换', backend_tag(deploy) == new_tag, backend_tag(deploy))
            image = docker('inspect', BACKEND_CONTAINER, '--format', '{{.Config.Image}}').stdout.strip()
            check('容器运行新镜像', image == f'dafeiyu-backend:{new_tag}', image)
            result = run(['bash', 'ops/status.sh'], cwd=deploy)
            check('升级后 ops/status.sh 可运行', result.returncode == 0, result.stderr[-200:])
            check('升级后暂停保持（T4：暂停不被覆盖）', intent_state(deploy).get('enabled') is False)
            # 容器重建后面板端口随机轮换，必须从新容器日志重新取
            url = control_url()
            check('升级后控制页已重新公布', url is not None)
            if url is None:
                raise SystemExit('升级后未公布控制页：' + logs()[-500:])
            port, token = split_url(url)
            check('升级后未自动连接/运行',
                  not status(port, token)['connected'] and not status(port, token)['running'])
            snap_after_upgrade = tree_hashes(deploy / 'data')
            diff = {k for k in set(snap1) | set(snap_after_upgrade)
                    if snap1.get(k) != snap_after_upgrade.get(k)}
            check('升级保留 data/ 全部文件与内容', not diff, f'差异文件：{sorted(diff)[:8]}')
            def endpoint_on_disk():
                try:
                    text = subprocess.run(['sudo', 'cat', str(deploy / 'data' / 'qq-state.json')],
                                          capture_output=True, text=True, check=True).stdout
                    return json.loads(text).get('config', {}).get('endpoint')
                except Exception:
                    return None

            saved_endpoint = wait_until(lambda: (lambda e: e if e == f'ws://127.0.0.1:{fixture_port}' else None)(
                endpoint_on_disk()), 20)
            check('连接配置仍在 qq-state.json', saved_endpoint is not None,
                  f'实际值：{endpoint_on_disk()}，期望 ws://127.0.0.1:{fixture_port}')

            # 升级后功能完好：再授权 → 运行 → 再暂停（供回滚阶段对照）
            action(port, token, {'action': 'connect'})
            state = wait_until(lambda: (lambda s: s if s['connected'] else None)(status(port, token)), 30)
            check('升级后可重新连接', state is not None, logs()[-300:])
            action(port, token, {'action': 'start', 'durationMinutes': 120})
            state = wait_until(lambda: (lambda s: s if s['running'] else None)(status(port, token)), 30)
            check('升级后可重新开始运行', state is not None)
            action(port, token, {'action': 'pause'})
            time.sleep(2)
            snap2 = tree_hashes(deploy / 'data')

            print('\n===== E. 回滚演练 =====')
            result = run(['bash', 'ops/rollback.sh'], cwd=deploy, timeout=600)
            check('ops/rollback.sh 成功', result.returncode == 0,
                  (result.stdout[-500:] + result.stderr[-500:]) if result.returncode else '')
            if result.returncode != 0:
                raise SystemExit('回滚演练失败')
            check('compose 标签已回滚', backend_tag(deploy) == main_tag, backend_tag(deploy))
            image = docker('inspect', BACKEND_CONTAINER, '--format', '{{.Config.Image}}').stdout.strip()
            check('容器运行回滚后镜像', image == f'dafeiyu-backend:{main_tag}', image)
            check('回滚后暂停保持', intent_state(deploy).get('enabled') is False)
            url = control_url()
            check('回滚后控制页已重新公布', url is not None)
            if url is not None:
                port, token = split_url(url)
                check('回滚后未自动连接/运行',
                      not status(port, token)['connected'] and not status(port, token)['running'])
            check('回滚保留 data/', tree_hashes(deploy / 'data') == snap2)

        print('\n===== F. 恢复演练（登录卷快照保护 + 绝对路径） =====')
        result = docker(*compose_args, 'config', '--format', 'json', cwd=deploy)
        check('compose config --format json 可用', result.returncode == 0, result.stderr[-200:])
        project = json.loads(result.stdout)['name']
        vol = f'{project}_qq-ai-data'
        created_volume = vol
        img_main = f'dafeiyu-backend:{main_tag}'
        docker('volume', 'create', vol)
        # 模拟运行过的 NapCat：卷里有旧登录痕迹
        docker('run', '--rm', '-u', '0', '--entrypoint', 'sh', '-v', f'{vol}:/dest', img_main,
               '-c', 'echo old-login > /dest/old-login.txt')
        result = run(['bash', 'ops/backup.sh', '--stop', '--label', 'restore-drill'],
                     cwd=deploy, timeout=600)
        check('backup.sh --stop 全量备份成功（含登录卷）', result.returncode == 0,
              (result.stdout[-400:] + result.stderr[-400:]) if result.returncode else '')
        if result.returncode != 0:
            raise SystemExit('恢复演练的备份步骤失败')
        drill_backup = sorted((deploy / 'backups').glob('restore-drill-*'))[-1]
        check('备份包含登录卷 tar', (drill_backup / 'qq-ai-data.tar.gz').is_file())

        docker(*compose_args, 'stop', 'backend', cwd=deploy)
        # 备份之后卷又发生了变化：恢复若不先快照，这份较新内容会直接丢失
        docker('run', '--rm', '-u', '0', '--entrypoint', 'sh', '-v', f'{vol}:/dest', img_main,
               '-c', 'echo newer-state > /dest/newer-state.txt')
        result = run(['bash', 'ops/restore.sh', str(drill_backup.resolve())],
                     cwd=deploy, timeout=600)
        check('ops/restore.sh 接受绝对备份路径并成功', result.returncode == 0,
              (result.stdout[-400:] + result.stderr[-400:]) if result.returncode else '')
        if result.returncode != 0:
            raise SystemExit('恢复演练失败')
        snapshots = sorted((deploy / 'backups').glob('pre-restore-*-qq-ai-data.tar.gz'))
        check('清空前登录卷已被快照到 backups/', bool(snapshots))
        if snapshots:
            listing = docker('run', '--rm', '--entrypoint', 'tar',
                             '-v', f'{snapshots[-1].resolve()}:/snapshot:ro', img_main, 'tzf', '/snapshot')
            check('快照保留了恢复前的较新内容', 'newer-state.txt' in listing.stdout,
                  listing.stdout[-200:])
        listing = docker('run', '--rm', '--entrypoint', 'sh', '-v', f'{vol}:/dest:ro', img_main,
                         '-c', 'ls /dest')
        check('恢复后卷内容与备份一致',
              'old-login.txt' in listing.stdout and 'newer-state.txt' not in listing.stdout,
              listing.stdout)
        baseline = snap2 if upgrade_pkg else snap1
        check('恢复保留 data/ 与暂停状态',
              tree_hashes(deploy / 'data') == baseline
              and intent_state(deploy).get('enabled') is False)
    finally:
        docker(*compose_args, 'down', '--remove-orphans', cwd=deploy, timeout=120)
        if created_volume:
            docker('volume', 'rm', '-f', created_volume)
        fixture.terminate()
        try:
            fixture.wait(timeout=10)
        except subprocess.TimeoutExpired:
            fixture.kill()

    print()
    if failures:
        print(f'{len(failures)} 项未通过：')
        for item in failures:
            print('  - ' + item)
        sys.exit(1)
    print('部署包演练全部通过')


if __name__ == '__main__':
    main()
