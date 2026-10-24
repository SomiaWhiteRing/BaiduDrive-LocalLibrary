# SPDX-License-Identifier: MIT
"""Local WebDAV adapter: logical empty files have registered, nonempty Baidu bodies.

Only registered exact bodies are decoded. All credentials are forwarded to
OpenList, never saved. SQLite and its initialization sentinel must be backed up
together. An ambiguous write fails closed until a successful replacement PUT.
"""
import base64
import contextlib
import email.utils
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import secrets
import sqlite3
import tempfile
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET

import httpx

DAV = '{DAV:}'
MAGIC = b'BaiduDrive empty-file v1\n'
EMPTY_SHA = hashlib.sha256(b'').hexdigest().encode('ascii')
MAX_XML = 16 * 1024 * 1024
HOP = {'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
       'te', 'trailer', 'transfer-encoding', 'upgrade', 'host', 'content-length', 'expect'}


def marker():
    return MAGIC + secrets.token_hex(32).encode('ascii') + b'\nsha256=' + EMPTY_SHA + b'\n'


def canonical(target):
    p = urllib.parse.urlsplit(target)
    if p.query or p.fragment:
        raise ValueError('WebDAV query/fragment is unsupported.')
    path = urllib.parse.unquote(p.path, encoding='utf-8', errors='strict')
    if not (path == '/dav' or path.startswith('/dav/')):
        raise ValueError('Only the dedicated /dav namespace is allowed.')
    parts = path.rstrip('/').split('/')
    if any(x in ('.', '..') for x in parts) or '\\' in path or '\0' in path:
        raise ValueError('Unsafe WebDAV path.')
    if any(not x for x in parts[1:]):
        raise ValueError('Ambiguous WebDAV path.')
    return path.rstrip('/')


def quoted(path):
    return urllib.parse.quote(path, safe='/')


def inside(path, prefix):
    return path == prefix or path.startswith(prefix + '/')


def scope_for(auth):
    if not auth or not auth.startswith('Basic '):
        return None
    try:
        decoded = base64.b64decode(auth[6:], validate=True)
        user, password = decoded.split(b':', 1)
        if not user or not password:
            return None
        return hashlib.sha256(user).hexdigest()
    except (ValueError, TypeError):
        return None


class Catalog:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        db = self.root / 'empty-files.sqlite'
        sentinel = self.root / 'initialized-v1'
        if sentinel.exists() and not db.exists():
            raise RuntimeError('Empty-file catalog is missing. Restore its backup before starting.')
        self.db = sqlite3.connect(db, check_same_thread=False)
        self.lock = threading.RLock()
        self.db.executescript('''PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
          CREATE TABLE IF NOT EXISTS files(scope TEXT,path TEXT,payload BLOB,PRIMARY KEY(scope,path));
          CREATE TABLE IF NOT EXISTS writes(scope TEXT,path TEXT,kind TEXT,payload BLOB,PRIMARY KEY(scope,path));
          CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY,scope TEXT,src TEXT,dst TEXT,kind TEXT);
          CREATE TABLE IF NOT EXISTS mtimes(scope TEXT,path TEXT,mtime INTEGER,PRIMARY KEY(scope,path));
        ''')
        sentinel.write_text('Keep this directory with your BaiduDrive service backups.\n', encoding='utf-8')

    def close(self):
        self.db.close()

    def entries(self, scope, path):
        with self.lock:
            self.check_operations(scope, path)
            old = self.db.execute('SELECT payload FROM files WHERE scope=? AND path=?', (scope, path)).fetchone()
            pending = self.db.execute('SELECT kind,payload FROM writes WHERE scope=? AND path=?', (scope, path)).fetchone()
            if pending and pending[0] == 'normal' and old:
                raise CodecError(503, 'An interrupted replacement PUT must be retried.')
            if pending and pending[0] == 'normal':
                # Unregistered ordinary files need no marker interpretation.
                # Preserve physical bytes/404 instead of disabling a complete
                # mount after an ambiguous ordinary PUT response.
                return []
            return [x for x in (pending[1] if pending else None, old[0] if old else None) if x is not None]

    def check_operations(self, scope, path):
        with self.lock:
            for src, dst in self.db.execute('SELECT src,dst FROM operations WHERE scope=?', (scope,)):
                if inside(path, src) or dst and inside(path, dst):
                    raise CodecError(503, 'An interrupted namespace operation needs recovery.')

    def recover_empty(self, scope, path, payload):
        with self.lock, self.db:
            pending = self.db.execute('SELECT kind FROM writes WHERE scope=? AND path=?', (scope, path)).fetchone()
            if pending and pending[0] == 'empty':
                self.commit_put(scope, path, payload)

    def begin_put(self, scope, path, payload):
        with self.lock, self.db:
            self.check_operations(scope, path)
            self.db.execute('INSERT OR REPLACE INTO writes VALUES(?,?,?,?)',
                            (scope, path, 'empty' if payload else 'normal', payload))

    def commit_put(self, scope, path, payload):
        with self.lock, self.db:
            self.db.execute('DELETE FROM files WHERE scope=? AND path=?', (scope, path))
            if payload:
                self.db.execute('INSERT INTO files VALUES(?,?,?)', (scope, path, payload))
            self.db.execute('DELETE FROM writes WHERE scope=? AND path=?', (scope, path))
            self.db.execute('DELETE FROM mtimes WHERE scope=? AND path=?', (scope, path))

    def mtime(self, scope, path):
        with self.lock:
            row = self.db.execute('SELECT mtime FROM mtimes WHERE scope=? AND path=?', (scope, path)).fetchone()
            return row[0] if row else None

    def set_mtime(self, scope, path, value):
        with self.lock, self.db:
            self.db.execute('INSERT OR REPLACE INTO mtimes VALUES(?,?,?)', (scope, path, value))

    def subtree(self, table, scope, prefix, value):
        return list(self.db.execute('SELECT path,' + value + ' FROM ' + table +
             ' WHERE scope=? AND path=? UNION ALL SELECT path,' + value + ' FROM ' + table +
             ' WHERE scope=? AND path>=? AND path<?', (scope, prefix, scope, prefix+'/', prefix+'0')))

    def remove_subtree(self, table, scope, prefix):
        self.db.execute('DELETE FROM '+table+' WHERE scope=? AND path=?', (scope, prefix))
        self.db.execute('DELETE FROM '+table+' WHERE scope=? AND path>=? AND path<?', (scope, prefix+'/', prefix+'0'))

    def namespace_begin(self, scope, src, dst, kind):
        with self.lock, self.db:
            self.check_operations(scope, src)
            if dst:
                self.check_operations(scope, dst)
            for p, pending_kind in self.db.execute('SELECT path,kind FROM writes WHERE scope=?', (scope,)):
                if inside(p, src) or dst and inside(p, dst):
                    registered = self.db.execute('SELECT 1 FROM files WHERE scope=? AND path=?',(scope,p)).fetchone()
                    if pending_kind != 'normal' or registered:
                        raise CodecError(503, 'A pending PUT must be recovered first.')
            op = secrets.token_hex(16)
            self.db.execute('INSERT INTO operations VALUES(?,?,?,?,?)', (op, scope, src, dst, kind))
            return op

    def namespace_finish(self, op, success):
        with self.lock, self.db:
            scope, src, dst, kind = self.db.execute('SELECT scope,src,dst,kind FROM operations WHERE id=?', (op,)).fetchone()
            if success:
                self.remove_subtree('writes',scope,src)
                if dst:
                    self.remove_subtree('writes',scope,dst)
                for table, value in (('files','payload'), ('mtimes','mtime')):
                    selected = self.subtree(table, scope, src, value)
                    if kind != 'COPY':
                        self.remove_subtree(table, scope, src)
                    if dst:
                        self.remove_subtree(table, scope, dst)
                    if kind in ('MOVE', 'COPY'):
                        self.db.executemany('INSERT OR REPLACE INTO '+table+' VALUES(?,?,?)',
                                            [(scope, dst + p[len(src):], b) for p, b in selected])
            self.db.execute('DELETE FROM operations WHERE id=?', (op,))


class CodecError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class NamespaceLock:
    """Concurrent uploads to different paths; exclusive folder moves/deletes."""
    def __init__(self):
        self.cv = threading.Condition()
        self.readers = self.writers_waiting = 0
        self.writer = False

    @contextlib.contextmanager
    def acquire(self, write=False):
        with self.cv:
            if write:
                self.writers_waiting += 1
                try:
                    self.cv.wait_for(lambda: not self.writer and not self.readers)
                    self.writer = True
                finally:
                    self.writers_waiting -= 1
            else:
                self.cv.wait_for(lambda: not self.writer and not self.writers_waiting)
                self.readers += 1
        try:
            yield
        finally:
            with self.cv:
                if write:
                    self.writer = False
                else:
                    self.readers -= 1
                self.cv.notify_all()


class CodecServer(ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, address, upstream, root, user='library-storage'):
        super().__init__(address, Handler)
        parsed = urllib.parse.urlsplit(upstream)
        if parsed.scheme != 'http' or parsed.hostname not in ('openlist', '127.0.0.1') or parsed.path not in ('', '/'):
            raise ValueError('Upstream must be the local OpenList service.')
        self.upstream = upstream.rstrip('/')
        self.user_scope = hashlib.sha256(user.encode()).hexdigest()
        self.catalog = Catalog(root)
        self.namespace = NamespaceLock()
        self.path_locks = [threading.RLock() for _ in range(257)]
        self.client = httpx.Client(trust_env=False, timeout=httpx.Timeout(600, connect=15),
                                   limits=httpx.Limits(max_connections=24, max_keepalive_connections=12))
        self.capacity = threading.BoundedSemaphore(24)
        self.authenticated = {}
        self.auth_lock = threading.Lock()
        self.temp = self.catalog.root / 'temporary'
        self.temp.mkdir(exist_ok=True)

    def server_close(self):
        super().server_close()
        self.client.close()
        self.catalog.close()


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'BaiduDriveEmptyCodec/1.0'

    def log_message(self, *args):
        pass  # Paths, headers and credentials must not enter container logs.

    def reply(self, status, content=b'', headers=None):
        self.send_response(status)
        for k, v in (headers or {}).items():
            if k.lower() not in HOP | {'server', 'date'}:
                self.send_header(k, v)
        self.send_header('Content-Length', str(len(content)))
        if self.close_connection:
            self.send_header('Connection', 'close')
        self.end_headers()
        if self.command != 'HEAD' and content:
            self.wfile.write(content)

    def body_chunks(self):
        transfer = self.headers.get('Transfer-Encoding', '').lower()
        if transfer:
            if transfer != 'chunked':
                raise CodecError(400, 'Unsupported transfer encoding.')
            while True:
                line = self.rfile.readline(8192)
                if not line.endswith(b'\r\n'):
                    raise CodecError(400, 'Invalid chunk header.')
                size = int(line.split(b';')[0], 16)
                if size < 0:
                    raise CodecError(400, 'Invalid chunk size.')
                if size == 0:
                    for _ in range(100):
                        trailer = self.rfile.readline(8192)
                        if trailer == b'\r\n':
                            return
                        if not trailer or not trailer.endswith(b'\r\n'):
                            raise CodecError(400, 'Invalid chunk trailer.')
                    raise CodecError(400, 'Too many chunk trailers.')
                    return
                while size:
                    chunk = self.rfile.read(min(size, 1024 * 1024))
                    if not chunk:
                        raise CodecError(400, 'Incomplete request body.')
                    size -= len(chunk)
                    yield chunk
                if self.rfile.read(2) != b'\r\n':
                    raise CodecError(400, 'Invalid chunk ending.')
        else:
            size = int(self.headers.get('Content-Length', '0'))
            if size < 0:
                raise CodecError(400, 'Invalid content length.')
            while size:
                chunk = self.rfile.read(min(size, 1024 * 1024))
                if not chunk:
                    raise CodecError(400, 'Incomplete request body.')
                size -= len(chunk)
                yield chunk

    def limited_body(self):
        body = bytearray()
        for chunk in self.body_chunks():
            body.extend(chunk)
            if len(body) > MAX_XML:
                raise CodecError(413, 'WebDAV metadata body exceeds its limit.')
        return bytes(body)

    def headers_upstream(self):
        # Never request compressed data: the body must retain exact bytes.
        h = {k: v for k, v in self.headers.items() if k.lower() not in HOP | {'accept-encoding'}}
        h['Accept-Encoding'] = 'identity'
        return h

    def verified_empty(self, path, candidates):
        headers = {'Authorization': self.headers['Authorization'], 'Accept-Encoding': 'identity'}
        with self.server.client.stream('GET', self.server.upstream + quoted(path),
                                       headers=headers, follow_redirects=True) as r:
            if r.status_code != 200:
                raise CodecError(r.status_code if r.status_code >= 400 else 502, 'Registered marker could not be verified.')
            body = bytearray()
            for chunk in r.iter_raw(chunk_size=256):
                body.extend(chunk)
                if len(body) > 1024:
                    raise CodecError(409, 'Registered empty file was changed outside the adapter.')
            payload = bytes(body)
            if payload not in candidates:
                raise CodecError(409, 'Registered empty file was changed outside the adapter.')
            self.server.catalog.recover_empty(scope_for(self.headers['Authorization']), path, payload)
            return payload, dict(r.headers)

    def authorize_mutation(self):
        fingerprint = hashlib.sha256(self.headers['Authorization'].encode()).hexdigest()
        with self.server.auth_lock:
            if self.server.authenticated.get(fingerprint, 0) > time.monotonic():
                return
        r = self.server.client.request('PROPFIND', self.server.upstream + '/dav/',
                                       headers={'Authorization': self.headers['Authorization'], 'Depth': '0'},
                                       content=b'<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>')
        if r.status_code != 207:
            raise CodecError(r.status_code if r.status_code >= 400 else 502, 'WebDAV authorization check failed.')
        with self.server.auth_lock:
            self.server.authenticated = {k: v for k, v in self.server.authenticated.items() if v > time.monotonic()}
            self.server.authenticated[fingerprint] = time.monotonic() + 30

    @staticmethod
    def etag(payload):
        return '"empty-v1-' + hashlib.sha256(payload).hexdigest() + '"'

    def empty_read(self, path, candidates):
        payload, headers = self.verified_empty(path, candidates)
        etag = self.etag(payload)
        headers['etag'] = etag
        mtime = self.server.catalog.mtime(scope_for(self.headers['Authorization']), path)
        if mtime is not None:
            headers['last-modified'] = email.utils.formatdate(mtime, usegmt=True)
        for key in ('content-md5', 'content-encoding', 'content-range'):
            headers.pop(key, None)
        if self.headers.get('If-Match') not in (None, '*', etag):
            return self.reply(412)
        if self.headers.get('If-None-Match') in ('*', etag):
            return self.reply(304, headers={'ETag': etag})
        if self.headers.get('Range'):
            return self.reply(416, headers={'Content-Range': 'bytes */0', 'ETag': etag})
        return self.reply(200, headers=headers)

    def translate_conditions(self, h, path, scope):
        candidates = self.server.catalog.entries(scope, path)
        if not candidates:
            return
        payload, original = self.verified_empty(path, candidates)
        virtual = self.etag(payload)
        physical = original.get('etag')
        for key in list(h):
            if key.lower() in ('if-match', 'if-none-match', 'if') and virtual in h[key]:
                if not physical:
                    raise CodecError(412, 'The upstream did not supply a conditional version.')
                h[key] = h[key].replace(virtual, physical)

    def put(self, path, scope):
        h = self.headers_upstream()
        # Check prior registration before starting the journal. A replacement
        # retry may recover a pending normal PUT without reading the old body.
        if any(x in self.headers for x in ('If', 'If-Match', 'If-None-Match')):
            self.translate_conditions(h, path, scope)
        length = self.headers.get('Content-Length')
        temporary = None
        try:
            # Receive the complete body in the state directory before forwarding. Some upstream
            # uploaders commit a short object when a streaming sender aborts.
            if length is not None and not 0 <= int(length) <= 32 * 1024**3:
                raise CodecError(413, 'Upload exceeds configured size limit.')
            temporary = tempfile.TemporaryFile(dir=self.server.temp)
            size = 0
            for chunk in self.body_chunks():
                size += len(chunk)
                if size > 32 * 1024**3:
                    raise CodecError(413, 'Upload exceeds configured 32 GiB limit.')
                temporary.write(chunk)
            if length is not None and size != int(length):
                raise CodecError(400, 'Incomplete request body; upstream unchanged.')
            temporary.seek(0)
            body = iter(lambda: temporary.read(1024 * 1024), b'')
            payload = marker() if size == 0 else None
            if payload:
                body = payload
                h = {k: v for k, v in h.items() if k.lower() not in ('content-md5', 'oc-checksum')}
            h['Content-Length'] = str(len(payload) if payload else size)
            self.server.catalog.begin_put(scope, path, payload)
            # OpenList responds only after Baidu has finished every part. This
            # can exceed ten minutes for large files; per-part timeouts belong
            # to the Baidu driver, not the local adapter's response wait.
            with self.server.client.stream('PUT', self.server.upstream + quoted(path), headers=h, content=body,
                                           timeout=httpx.Timeout(600, connect=15, read=None)) as r:
                response = r.read()
                status, response_headers = r.status_code, dict(r.headers)
            if 200 <= status < 300:
                if payload:
                    self.verified_empty(path, [payload])
                    response_headers['etag'] = self.etag(payload)
                self.server.catalog.commit_put(scope, path, payload)
            # Failed/ambiguous writes retain their intent. Retrying a successful
            # PUT clears it; no unregistered marker becomes a zero-byte file.
            self.reply(status, response, response_headers)
        finally:
            if temporary:
                temporary.close()

    def propfind(self, path, scope):
        h = self.headers_upstream()
        r = self.server.client.request('PROPFIND', self.server.upstream + quoted(path),
                                       headers=h, content=self.limited_body())
        if r.status_code != 207:
            return self.reply(r.status_code, r.content, dict(r.headers))
        if len(r.content) > MAX_XML:
            raise CodecError(502, 'Upstream WebDAV listing exceeds metadata limit.')
        root = ET.fromstring(r.content)
        changed = False
        for response in root.findall(DAV + 'response'):
            href = response.find(DAV + 'href')
            if href is None or not href.text:
                continue
            p = canonical(href.text)
            child_lock = self.server.path_locks[hash((scope, p)) % len(self.server.path_locks)]
            with child_lock:
                candidates = self.server.catalog.entries(scope, p)
                mtime = self.server.catalog.mtime(scope, p)
                if not candidates and mtime is None:
                    continue
                payload = self.verified_empty(p, candidates)[0] if candidates else None
            for propstat in response.findall(DAV + 'propstat'):
                status = propstat.findtext(DAV + 'status', '')
                if ' 200 ' not in status:
                    continue
                prop = propstat.find(DAV + 'prop')
                if prop is None:
                    continue
                for item in prop:
                    if item.tag == DAV + 'getcontentlength' and payload:
                        item.text = '0'
                    elif item.tag == DAV + 'getetag' and payload:
                        item.text = self.etag(payload)
                    elif item.tag == DAV + 'getlastmodified' and mtime is not None:
                        item.text = email.utils.formatdate(mtime, usegmt=True)
                    elif item.tag.endswith('}checksums') and payload:
                        item.text = ''
                        for child in list(item):
                            item.remove(child)
            changed = True
        content = ET.tostring(root, encoding='utf-8', xml_declaration=True) if changed else r.content
        self.reply(207, content, dict(r.headers))

    def proppatch(self, path, scope):
        body = self.limited_body()
        root = ET.fromstring(body)
        props = root.findall(DAV+'set/'+DAV+'prop/*')
        if len(props) != 1 or props[0].tag not in (DAV+'lastmodified', DAV+'getlastmodified') or root.find(DAV+'remove') is not None:
            return self.reply(501, b'Only last-modified metadata is supported.\n')
        text = props[0].text or ''
        try:
            value = int(text) if text.isdigit() else int(email.utils.parsedate_to_datetime(text).timestamp())
        except (ValueError, TypeError, AttributeError, OverflowError):
            raise CodecError(400, 'Invalid modification time.')
        if not 0 <= value <= 253402300799:
            raise CodecError(400, 'Modification time is out of range.')
        # Read through authenticated upstream before changing virtual metadata.
        h = {'Authorization': self.headers['Authorization'], 'Depth': '0'}
        r = self.server.client.request('PROPFIND', self.server.upstream + quoted(path), headers=h,
                                       content=b'<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>')
        if r.status_code != 207:
            return self.reply(r.status_code, r.content, dict(r.headers))
        candidates = self.server.catalog.entries(scope, path)
        if candidates:
            self.verified_empty(path, candidates)
        self.server.catalog.set_mtime(scope, path, value)
        response = ET.Element(DAV+'multistatus')
        entry = ET.SubElement(response, DAV+'response')
        ET.SubElement(entry, DAV+'href').text = quoted(path)
        stat = ET.SubElement(entry, DAV+'propstat')
        prop = ET.SubElement(stat, DAV+'prop')
        ET.SubElement(prop, props[0].tag)
        ET.SubElement(stat, DAV+'status').text = 'HTTP/1.1 200 OK'
        self.reply(207, ET.tostring(response, encoding='utf-8', xml_declaration=True), {'Content-Type':'application/xml; charset=utf-8'})

    def namespace_operation(self, path, scope):
        h = self.headers_upstream()
        dst = None
        if self.command in ('MOVE', 'COPY'):
            destination = self.headers.get('Destination', '')
            parsed = urllib.parse.urlsplit(destination)
            if parsed.netloc and parsed.netloc != self.headers.get('Host'):
                raise CodecError(400, 'Destination must remain inside this WebDAV service.')
            dst = canonical(destination)
            if dst == path or inside(dst, path) or inside(path, dst):
                raise CodecError(409, 'Overlapping namespace operation is unsupported.')
            h['Destination'] = self.server.upstream + quoted(dst)
            candidates = self.server.catalog.entries(scope, path)
            if self.command == 'COPY' and candidates:
                # Baidu/OpenList COPY cannot copy to a different filename in
                # the same parent. A registered empty file is small enough to
                # copy as a freshly verified PUT while preserving its meaning.
                return self.copy_empty(path, dst, scope, candidates)
        self.translate_conditions(h, path, scope)
        op = self.server.catalog.namespace_begin(scope, path, dst, self.command)
        r = self.server.client.request(self.command, self.server.upstream + quoted(path), headers=h,
                                       content=self.limited_body())
        if 200 <= r.status_code < 300 and r.status_code != 207:
            self.server.catalog.namespace_finish(op, True)
        elif r.status_code in (400, 401, 403, 404, 405, 409, 412, 423):
            self.server.catalog.namespace_finish(op, False)
        # A partial/ambiguous result leaves a durable block on both prefixes.
        self.reply(r.status_code, r.content, dict(r.headers))

    def copy_empty(self, src, dst, scope, candidates):
        original, _ = self.verified_empty(src, candidates)
        if self.headers.get('If-Match') not in (None, '*', self.etag(original)):
            raise CodecError(412, 'Source conditional version does not match.')
        h = {'Authorization': self.headers['Authorization'], 'Accept-Encoding': 'identity'}
        head = self.server.client.head(self.server.upstream + quoted(dst), headers=h)
        if head.status_code not in (200, 404):
            raise CodecError(head.status_code if head.status_code >= 400 else 409, 'Copy destination could not be checked.')
        if head.status_code == 200 and self.headers.get('Overwrite', 'T') == 'F':
            raise CodecError(412, 'Copy destination already exists.')
        payload = marker()
        self.server.catalog.begin_put(scope, dst, payload)
        r = self.server.client.put(self.server.upstream + quoted(dst), headers=h, content=payload)
        if 200 <= r.status_code < 300:
            self.verified_empty(dst, [payload])
            self.server.catalog.commit_put(scope, dst, payload)
            mtime = self.server.catalog.mtime(scope, src)
            if mtime is not None:
                self.server.catalog.set_mtime(scope, dst, mtime)
        self.reply(r.status_code, r.content, {'ETag': self.etag(payload)})

    def forward(self, path):
        h = self.headers_upstream()
        body = self.limited_body() if self.command not in ('GET', 'HEAD') else None
        with self.server.client.stream(self.command, self.server.upstream + quoted(path), headers=h,
                                       content=body, follow_redirects=self.command in ('GET', 'HEAD')) as r:
            self.send_response(r.status_code)
            mtime = self.server.catalog.mtime(scope_for(self.headers['Authorization']), path)
            for k, v in r.headers.items():
                if k.lower() not in HOP | {'server', 'date'}:
                    self.send_header(k, email.utils.formatdate(mtime, usegmt=True) if k.lower()=='last-modified' and mtime is not None else v)
            length = r.headers.get('Content-Length')
            if length is not None:
                self.send_header('Content-Length', length)
            elif self.command != 'HEAD' and r.status_code not in (204, 304):
                self.send_header('Connection', 'close')
                self.close_connection = True
            self.end_headers()
            if self.command != 'HEAD':
                for chunk in r.iter_raw(chunk_size=1024 * 1024):
                    self.wfile.write(chunk)

    def dispatch(self):
        self.connection.settimeout(600)
        if self.path == '/health' and self.command == 'GET':
            return self.reply(200, b'{"service":"empty-codec","version":1,"registered_empty_files":true,"logical_mtime":true}\n', {'Content-Type': 'application/json'})
        try:
            path = canonical(self.path)
            scope = scope_for(self.headers.get('Authorization'))
            if scope is None:
                self.close_connection = True
                return self.reply(401, headers={'WWW-Authenticate': 'Basic realm="BaiduDrive"', 'Connection': 'close'})
            if scope != self.server.user_scope:
                self.close_connection = True
                return self.reply(403, b'Dedicated WebDAV user required.\n', {'Connection':'close'})
            namespace_write = self.command in ('MOVE', 'COPY', 'DELETE')
            lock = (contextlib.nullcontext() if self.command == 'PROPFIND'
                    else self.server.path_locks[hash((scope, path)) % len(self.server.path_locks)])
            with self.server.capacity, self.server.namespace.acquire(namespace_write), lock:
                if self.command == 'PUT':
                    self.authorize_mutation()
                    return self.put(path, scope)
                candidates = self.server.catalog.entries(scope, path)
                if self.command in ('GET', 'HEAD') and candidates:
                    return self.empty_read(path, candidates)
                if self.command == 'PROPFIND':
                    return self.propfind(path, scope)
                if self.command == 'PROPPATCH':
                    self.authorize_mutation()
                    return self.proppatch(path, scope)
                if namespace_write:
                    self.authorize_mutation()
                    return self.namespace_operation(path, scope)
                return self.forward(path)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except (ValueError, ET.ParseError):
            self.close_connection = True
            self.reply(400, b'Invalid WebDAV request.\n', {'Connection': 'close'})
        except CodecError as e:
            self.close_connection = True
            self.reply(e.status, (str(e) + '\n').encode(), {'Connection': 'close'})
        except Exception as e:
            # Log only the exception class; upstream URLs may contain tokens.
            print(json.dumps({'error_type': type(e).__name__}), flush=True)
            self.close_connection = True
            self.reply(502, b'Upstream operation interrupted; write journal retained.\n', {'Connection': 'close'})

    do_GET = do_HEAD = do_PUT = do_PROPFIND = do_PROPPATCH = dispatch
    do_MOVE = do_COPY = do_DELETE = do_MKCOL = do_OPTIONS = do_LOCK = do_UNLOCK = dispatch


if __name__ == '__main__':
    server = CodecServer(('0.0.0.0', int(os.environ.get('PORT', '8080'))),
                         os.environ.get('UPSTREAM', 'http://openlist:5244'),
                         os.environ.get('STATE_DIR', '/state'), os.environ.get('WEBDAV_USER', 'library-storage'))
    try:
        server.serve_forever()
    finally:
        server.server_close()
