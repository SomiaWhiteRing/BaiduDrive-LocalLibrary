# SPDX-License-Identifier: MIT
"""BaiduPCS-Go links with bounded, ordered parallel HTTP ranges."""
import concurrent.futures
import contextlib
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time
import urllib.parse

import httpx


class PcsDownloads:
    minimum = 1024 * 1024
    chunk = 2 * 1024 * 1024
    window = 16

    def __init__(self, state):
        self.profile = Path(state) / 'pcs'
        self.executable = Path(os.environ.get('PCS_EXECUTABLE', '/state/tools/BaiduPCS-Go'))
        self.prefix = os.environ.get('OPENLIST_DAV_PATH', '/dav/baidu').rstrip('/')
        self.settings = self.profile / 'download.json'
        if not self.settings.exists():
            self.settings = self.profile / 'migration.json'
        if self.settings.is_file():
            self.prefix = json.loads(self.settings.read_text(encoding='utf-8-sig')).get('dav_prefix', self.prefix).rstrip('/')
        self.mode = os.environ.get('BAIDUDRIVE_PCS_DOWNLOAD', 'fallback')
        self.enabled = (self.mode in ('fallback', 'prefer', '1')
                        and self.executable.is_file() and self.settings.is_file())
        self.prefer = self.mode in ('prefer', '1')
        self.lock = threading.Lock()
        self.links = {}
        self.hints = {}
        self.agent = 'netdisk'
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=24, thread_name_prefix='pcs-range')
        self.client = httpx.Client(trust_env=False, timeout=httpx.Timeout(45, connect=10),
                                  limits=httpx.Limits(max_connections=24, max_keepalive_connections=16))

    def close(self):
        self.pool.shutdown(wait=True, cancel_futures=True)
        self.client.close()

    def hint(self, path, size):
        # A size hint only selects the download path. Authenticated HEAD still
        # validates every selected read and its conditional headers.
        with self.lock:
            if size >= self.minimum:
                if len(self.hints) >= 8192:
                    self.hints.pop(next(iter(self.hints)))
                self.hints[path] = (time.monotonic()+600, size)
            else:
                self.hints.pop(path, None)

    def eligible(self, path, requested_range):
        if not self.enabled or not path.startswith(self.prefix + '/'):
            return False
        match = re.fullmatch(r'bytes=(\d*)-(\d*)', requested_range or '')
        if requested_range and (not match or not any(match.groups())):
            return False
        if match and match[2]:
            length = int(match[2])-int(match[1])+1 if match[1] else int(match[2])
            if length < self.minimum:
                return False
        with self.lock:
            hint = self.hints.get(path)
        if hint and hint[0] > time.monotonic():
            return True
        match = re.fullmatch(r'bytes=(\d+)-(\d+)', requested_range or '')
        return bool(match and int(match[2])-int(match[1])+1 >= self.minimum)

    def invalidate(self, path):
        if path != self.prefix and not path.startswith(self.prefix + '/'):
            return
        relative = path[len(self.prefix):].strip('/')
        with self.lock:
            for key in list(self.links):
                if not relative or key[0] == relative or key[0].startswith(relative+'/'):
                    del self.links[key]
            for key in list(self.hints):
                if key == path or key.startswith(path+'/'):
                    del self.hints[key]

    def locate(self, relative, version):
        key = (relative, version)
        with self.lock:
            old = self.links.get(key)
            if old and old[0] > time.monotonic():
                return old[1]
        settings = json.loads(self.settings.read_text(encoding='utf-8-sig'))
        config = json.loads((self.profile / 'pcs_config.json').read_text(encoding='utf-8-sig'))
        if str(config.get('baidu_active_uid')) != str(settings['account_uid']) or config.get('proxy') or not config.get('enable_https'):
            raise RuntimeError('Private PCS account or direct HTTPS policy changed.')
        # Locate links are bound to the Android client class. A generic UA can
        # return 31362 for larger files even when small files work.
        self.agent = config.get('pan_ua') or 'netdisk'
        env = {k: v for k, v in os.environ.items()
               if k.lower() not in ('http_proxy', 'https_proxy', 'all_proxy', 'baidupcs_go_verbose')}
        env.update(BAIDUPCS_GO_CONFIG_DIR=str(self.profile), NO_PROXY='*')
        remote = settings['remote_root'].rstrip('/') + '/' + relative
        result = subprocess.run([str(self.executable), 'locate', remote], env=env,
                                input=b'', capture_output=True, timeout=40)
        urls = []
        for value in re.findall(r'https?://[^\s<>]+', result.stdout.decode('utf-8', errors='replace')):
            value = value.rstrip('\"\'`,;)]}')
            parsed = urllib.parse.urlsplit(value)
            host = (parsed.hostname or '').lower()
            if (parsed.scheme == 'https' and not parsed.username and not parsed.password
                and (host.endswith('.baidupcs.com') or host == 'd.pcs.baidu.com')
                and value not in urls):
                urls.append(value)
        if result.returncode or not urls:
            raise RuntimeError('PCS did not return an authorized HTTPS data link.')
        with self.lock:
            if len(self.links) >= 128:
                self.links.pop(next(iter(self.links)))
            self.links[key] = (time.monotonic() + 600, urls)
        return urls

    def piece(self, urls, start, end, size):
        for index in range(min(2, len(urls))):
            try:
                with self.client.stream('GET', urls[index], headers={
                    'Range': f'bytes={start}-{end}', 'Accept-Encoding': 'identity',
                    'User-Agent': self.agent}, follow_redirects=False) as response:
                    if (response.status_code != 206
                        or response.headers.get('Content-Range') != f'bytes {start}-{end}/{size}'
                        or response.headers.get('Content-Encoding', 'identity') != 'identity'):
                        raise RuntimeError('PCS data range was not honored.')
                    blocks = []; received = 0
                    for block in response.iter_raw():
                        received += len(block)
                        if received > end-start+1:
                            raise RuntimeError('PCS range exceeded its verified size.')
                        blocks.append(block)
                    if received != end-start+1:
                        raise RuntimeError('PCS data range was interrupted.')
                    return b''.join(blocks)
            except (httpx.HTTPError, RuntimeError):
                if index+1 == min(2, len(urls)):
                    raise

    @contextlib.contextmanager
    def prepare(self, relative, head, range_header):
        size = int(head['Content-Length'])
        start, end = 0, size-1
        if range_header:
            match = re.fullmatch(r'bytes=(\d*)-(\d*)', range_header)
            if not match or not any(match.groups()):
                raise ValueError('Unsupported range.')
            first, last = match.groups()
            if first:
                start = int(first); end = min(int(last), end) if last else end
            else:
                start = max(0, size-int(last))
        if start > end or end-start+1 < self.minimum:
            raise ValueError('Use the existing short-read path.')
        version = (head.get('ETag', ''), size, head.get('Last-Modified', ''))
        urls = self.locate(relative, version)
        piece_size = min(self.chunk, max(256*1024, ((end-start+1+self.window*65536-1)//(self.window*65536))*65536))
        pending = {}; cursor = start
        def submit():
            nonlocal cursor
            while cursor <= end and len(pending) < self.window:
                stop = min(end, cursor+piece_size-1)
                pending[cursor] = self.pool.submit(self.piece, urls, cursor, stop, size)
                cursor = stop+1
        def ordered():
            position = start
            while position <= end:
                value = pending.pop(position).result()
                yield value
                position += len(value)
                submit()
        try:
            submit()
            yield start, end, size, ordered()
        finally:
            for future in pending.values():
                future.cancel()
