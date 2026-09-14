"""Read Codex quota via the official stdio app-server protocol."""
from __future__ import annotations

import json
import math
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime


def find_codex() -> str:
    executable = shutil.which('codex')
    if executable and Path(executable).suffix.lower() == '.exe':
        return executable
    folder = Path(os.environ.get('LOCALAPPDATA', str(Path.home() / 'AppData/Local'))) / 'OpenAI/Codex/bin'
    candidates = list(folder.glob('*/codex.exe'))
    if not candidates:
        raise RuntimeError('未找到 Codex CLI，请安装或更新 Codex 桌面应用。')
    return str(max(candidates, key=lambda p: p.stat().st_mtime))


def read_rate_limits(timeout: float = 20.0) -> dict:
    proc = subprocess.Popen(
        [find_codex(), 'app-server', '--stdio'], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, encoding='utf-8', creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
        cwd=Path(__file__).parent,
    )
    messages: queue.Queue[dict | None] = queue.Queue()

    def reader() -> None:
        assert proc.stdout is not None
        try:
            for line in proc.stdout:
                try:
                    messages.put(json.loads(line))
                except json.JSONDecodeError:
                    continue
        finally:
            messages.put(None)

    threading.Thread(target=reader, daemon=True).start()
    deadline = time.monotonic() + timeout

    def send(message: dict) -> None:
        assert proc.stdin is not None
        proc.stdin.write(json.dumps(message, ensure_ascii=False) + '\n')
        proc.stdin.flush()

    def response(request_id: int) -> dict:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError('额度查询超时，请检查网络后重试。')
            try:
                message = messages.get(timeout=remaining)
            except queue.Empty as exc:
                raise RuntimeError('额度查询超时，请检查网络后重试。') from exc
            if message is None:
                raise RuntimeError('Codex 额度服务未能启动，请确认桌面应用已登录。')
            if message.get('id') != request_id:
                continue
            if 'error' in message:
                raise RuntimeError('Codex 额度读取失败，请确认使用 ChatGPT 账号登录并检查网络。')
            return message.get('result', {})

    try:
        send({'method': 'initialize', 'id': 1, 'params': {'clientInfo': {
            'name': 'furina_quota_pet', 'title': '芙宁娜额度宠物', 'version': '1.0.0'}}})
        response(1)
        send({'method': 'initialized', 'params': {}})
        send({'method': 'account/rateLimits/read', 'id': 2, 'params': {}})
        return response(2)
    finally:
        if proc.stdin:
            proc.stdin.close()
        if proc.poll() is None:
            proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
        if proc.stdout:
            proc.stdout.close()


def normalize_quota(data: dict) -> dict:
    buckets = data.get('rateLimitsByLimitId')
    if not isinstance(buckets, dict) or not buckets:
        legacy = data.get('rateLimits')
        buckets = {'codex': legacy} if isinstance(legacy, dict) else {}
    result: list[dict] = []
    for key, bucket in buckets.items():
        if not isinstance(bucket, dict):
            continue
        windows = []
        for kind in ('primary', 'secondary'):
            window = bucket.get(kind)
            if not isinstance(window, dict):
                continue
            used = window.get('usedPercent')
            valid = isinstance(used, (int, float)) and not isinstance(used, bool) and math.isfinite(used)
            timestamp = window.get('resetsAt')
            reset = None
            if isinstance(timestamp, (int, float)) and not isinstance(timestamp, bool):
                try:
                    reset = datetime.fromtimestamp(timestamp).astimezone().strftime('%m-%d %H:%M')
                except (OverflowError, OSError, ValueError):
                    pass
            windows.append({'kind': kind, 'minutes': window.get('windowDurationMins'),
                            'remaining': max(0.0, min(100.0, 100.0 - used)) if valid else None,
                            'resetLocal': reset, 'resetAt': timestamp if reset else None})
        if windows:
            result.append({'name': bucket.get('limitName') or key, 'windows': windows})
    if not result:
        raise RuntimeError('账号尚未返回额度信息，请确认 Codex 使用 ChatGPT 账号登录。')
    return {'ok': True, 'buckets': result, 'updatedLocal': datetime.now().astimezone().strftime('%H:%M:%S')}


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    try:
        print(json.dumps(normalize_quota(read_rate_limits()), ensure_ascii=False))
    except (RuntimeError, OSError, BrokenPipeError) as error:
        print(json.dumps({'ok': False, 'error': str(error)}, ensure_ascii=False))
        sys.exit(1)
