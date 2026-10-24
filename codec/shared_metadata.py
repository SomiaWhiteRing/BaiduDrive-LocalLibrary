# SPDX-License-Identifier: MIT
"""Replicate logical metadata through immutable records in the same Baidu directory.

SQLite connections, credentials, temporary uploads and local write journals stay
on each device. Remote intents make unfinished metadata mutations visible to
other devices. This is eventual replication, not a distributed filesystem lock.
"""
import base64
import gzip
import io
import json
import os
import re
import threading
import time
import uuid
import urllib.parse
import xml.etree.ElementTree as ET


class MetadataError(Exception):
    pass


class SharedMetadata:
    directory = '.baidulibrary'
    limit = 256 * 1024 * 1024

    def __init__(self, server):
        self.server = server
        self.enabled = os.environ.get('SHARED_METADATA', '0') == '1'
        self.prefix = os.environ.get('METADATA_DAV_PATH') or os.environ.get('OPENLIST_DAV_PATH', '/dav/baidu')
        self.prefix = self.prefix.rstrip('/')
        self.root = self.prefix + '/' + self.directory
        self.lock = threading.RLock()
        self.next_refresh = 0
        self.ready = False
        self.pending = {}
        self.manifest = None
        self.base = None
        self.clock = 0
        self.last = ''
        if not self.enabled:
            return
        with server.catalog.lock, server.catalog.db:
            server.catalog.db.executescript('''
              CREATE TABLE IF NOT EXISTS shared_settings(key TEXT PRIMARY KEY,value TEXT);
              CREATE TABLE IF NOT EXISTS shared_events(id TEXT PRIMARY KEY,data TEXT,uploaded INTEGER);
            ''')
            row = server.catalog.db.execute("SELECT value FROM shared_settings WHERE key='device'").fetchone()
            self.device = row[0] if row else uuid.uuid4().hex
            server.catalog.db.execute("INSERT OR IGNORE INTO shared_settings VALUES('device',?)", (self.device,))

    def relative(self, path):
        if path == self.prefix:
            return ''
        if not path.startswith(self.prefix + '/'):
            raise MetadataError('Path is outside the shared library.')
        return path[len(self.prefix)+1:]

    def absolute(self, relative):
        if (not isinstance(relative, str) or relative.startswith('/') or '\\' in relative
                or '\0' in relative or any(p in ('.', '..', '') for p in relative.split('/')) and relative != ''):
            raise MetadataError('Invalid shared metadata path.')
        return self.prefix + ('/' + relative if relative else '')

    def protects(self, path):
        return path == self.root or path.startswith(self.root + '/')

    def in_library(self, path):
        return path == self.prefix or path.startswith(self.prefix + '/')

    def request(self, auth, method, path, content=None):
        url = self.server.upstream + urllib.parse.quote(path, safe='/')
        with self.server.client.stream(method, url, headers={
                'Authorization': auth, 'Accept-Encoding': 'identity', 'Depth': '1',
                'Cache-Control': 'no-cache'}, content=content, follow_redirects=False) as response:
            body = bytearray()
            for block in response.iter_raw():
                body.extend(block)
                if len(body) > self.limit:
                    raise MetadataError('Shared metadata exceeds its size limit.')
            return response.status_code, bytes(body)

    def get(self, auth, path):
        status, body = self.request(auth, 'GET', path)
        if status != 200:
            raise MetadataError('Shared metadata read failed (HTTP %d).' % status)
        return body

    def put(self, auth, path, body):
        status, _ = self.request(auth, 'PUT', path, body)
        if status not in (200, 201, 204):
            raise MetadataError('Shared metadata write failed (HTTP %d).' % status)
        if self.get(auth, path) != body:
            raise MetadataError('Shared metadata readback differs from its write.')

    @staticmethod
    def encode(value):
        return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8')

    def records(self, path):
        catalog = self.server.catalog
        with catalog.lock:
            files = catalog.subtree('files', self.server.user_scope, path, 'payload')
            mtimes = catalog.subtree('mtimes', self.server.user_scope, path, 'mtime')
            return {
                'files': [[self.relative(p), base64.b64encode(v).decode('ascii')] for p, v in files],
                'mtimes': [[self.relative(p), v] for p, v in mtimes],
            }

    def unpack(self, body):
        with gzip.GzipFile(fileobj=io.BytesIO(body)) as stream:
            decoded = stream.read(self.limit + 1)
        if len(decoded) > self.limit:
            raise MetadataError('Shared snapshot exceeds its decoded size limit.')
        return json.loads(decoded)

    def bootstrap(self, auth, create=False):
        if not self.enabled:
            return {'enabled': False}
        with self.lock:
            status, body = self.request(auth, 'GET', self.root + '/format.json')
            if status == 404 and create:
                catalog = self.server.catalog
                with catalog.lock:
                    if catalog.db.execute('SELECT 1 FROM writes UNION ALL SELECT 1 FROM operations LIMIT 1').fetchone():
                        raise MetadataError('Complete local write recovery before publishing a shared snapshot.')
                for path in (self.root, self.root + '/events'):
                    code, _ = self.request(auth, 'MKCOL', path)
                    if code not in (200, 201, 204, 405):
                        raise MetadataError('Shared directory creation failed.')
                snapshot = 'base-' + uuid.uuid4().hex + '.json.gz'
                base = {'version': 1, **self.records(self.prefix)}
                self.put(auth, self.root + '/' + snapshot, gzip.compress(self.encode(base), mtime=0))
                # Each publisher has an immutable snapshot. The format record is
                # created only by the explicitly selected initial publisher.
                if self.request(auth, 'GET', self.root + '/format.json')[0] != 404:
                    raise MetadataError('Another publisher initialized this library. Join its metadata first.')
                manifest = {'version': 1, 'library': uuid.uuid4().hex, 'snapshot': snapshot}
                self.put(auth, self.root + '/format.json', self.encode(manifest))
                body = self.encode(manifest)
                status = 200
            if status != 200:
                raise MetadataError('Publish metadata on the existing device first (HTTP %d).' % status)
            manifest = json.loads(body)
            if (manifest.get('version') != 1 or not re.fullmatch(r'[a-f0-9]{32}', manifest.get('library', ''))
                    or not re.fullmatch(r'base-[a-f0-9]{32}\.json\.gz', manifest.get('snapshot', ''))):
                raise MetadataError('Unsupported shared metadata format.')
            catalog = self.server.catalog
            with catalog.lock:
                previous = catalog.db.execute("SELECT value FROM shared_settings WHERE key='library'").fetchone()
            if previous and previous[0] != manifest['library']:
                raise MetadataError('The shared library identity changed. Retain the local state and inspect its backup.')
            rebuild = not self.ready or self.manifest != manifest
            cache = catalog.root / ('shared-' + manifest['library'] + '-' + manifest['snapshot'])
            if self.manifest == manifest and self.base is not None:
                base = self.base
            else:
                compressed = cache.read_bytes() if cache.is_file() else self.get(auth, self.root + '/' + manifest['snapshot'])
                base = self.unpack(compressed)
                self.validate_records(base)
                if not cache.is_file():
                    temporary = cache.with_suffix('.pending')
                    temporary.write_bytes(compressed)
                    os.replace(temporary, cache)
            if base.get('version') != 1:
                raise MetadataError('Unsupported shared snapshot format.')
            self.manifest, self.base = manifest, base
            if rebuild:
                with catalog.lock:
                    row = catalog.db.execute("SELECT value FROM shared_settings WHERE key='replay_cursor'").fetchone()
                    cursor = json.loads(row[0]) if row else None
                    events = catalog.db.execute('SELECT COUNT(*) FROM shared_events').fetchone()[0]
                    unfinished = catalog.db.execute('SELECT 1 FROM writes UNION ALL SELECT 1 FROM operations LIMIT 1').fetchone()
                if cursor and (cursor.get('library'), cursor.get('prefix'), cursor.get('scope')) == (manifest['library'], self.prefix, self.server.user_scope):
                    self.last, self.clock, self.pending = cursor['last'], cursor['clock'], cursor['pending']
                    rebuild = False
                elif not events and not unfinished:
                    # The first publisher already owns this exact baseline.
                    # Compare logical records instead of rewriting its database.
                    current = self.records(self.prefix)
                    if all(dict(current[key]) == dict(base[key]) for key in ('files', 'mtimes')):
                        self.last, self.clock, self.pending = '', 0, {}
                        rebuild = False
                if not rebuild:
                    self.ready = True
            self.refresh(auth, force=True, rebuild=rebuild)
            with catalog.lock, catalog.db:
                catalog.db.execute("INSERT OR REPLACE INTO shared_settings VALUES('library',?)", (manifest['library'],))
            self.ready = True
            return self.status()

    def validate_records(self, record):
        files = []
        for path, encoded in record['files']:
            payload = base64.b64decode(encoded, validate=True)
            if not re.fullmatch(b'BaiduDrive empty-file v1\n[a-f0-9]{64}\nsha256='
                                b'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n', payload):
                raise MetadataError('Invalid shared empty-file registration.')
            files.append((self.server.user_scope, self.absolute(path), payload))
        mtimes = []
        for path, mtime in record['mtimes']:
            if type(mtime) is not int or not 0 <= mtime <= 253402300799:
                raise MetadataError('Invalid shared logical modification time.')
            mtimes.append((self.server.user_scope, self.absolute(path), mtime))
        return files, mtimes

    def apply_records(self, record):
        files, mtimes = self.validate_records(record)
        db = self.server.catalog.db
        db.executemany('INSERT OR REPLACE INTO files VALUES(?,?,?)', files)
        db.executemany('INSERT OR REPLACE INTO mtimes VALUES(?,?,?)', mtimes)

    def save_cursor(self):
        value = {'library': self.manifest['library'], 'prefix': self.prefix,
                 'scope': self.server.user_scope, 'last': self.last,
                 'clock': self.clock, 'pending': self.pending}
        self.server.catalog.db.execute("INSERT OR REPLACE INTO shared_settings VALUES('replay_cursor',?)",
                                       (self.encode(value).decode('utf-8'),))

    def apply(self, event):
        catalog = self.server.catalog
        if event['kind'] == 'intent':
            self.pending[event['id']] = event
        elif event['kind'] in ('commit', 'abort'):
            for identity in event['resolves']:
                self.pending.pop(identity, None)
            if event['kind'] == 'commit':
                for path in event['clear']:
                    for table in ('files', 'mtimes'):
                        catalog.remove_subtree(table, self.server.user_scope, self.absolute(path))
                self.apply_records(event)
        else:
            raise MetadataError('Unsupported shared metadata event.')
        self.clock = max(self.clock, event['clock'])

    def refresh(self, auth, force=False, rebuild=False):
        try:
            return self._refresh(auth, force, rebuild)
        except Exception:
            self.ready = False
            self.next_refresh = 0
            raise

    def _refresh(self, auth, force=False, rebuild=False):
        if not self.enabled:
            return
        with self.lock:
            if self.manifest is None or (not self.ready and not rebuild):
                return self.bootstrap(auth)
            if not force and time.monotonic() < self.next_refresh:
                return
            catalog = self.server.catalog
            with catalog.lock:
                outbox = list(catalog.db.execute('SELECT id,data FROM shared_events WHERE uploaded=0 ORDER BY id'))
                known = {row[0] for row in catalog.db.execute('SELECT id FROM shared_events')}
            for identity, data in outbox:
                self.put(auth, self.root + '/events/' + identity + '.json', data.encode('utf-8'))
                with catalog.lock, catalog.db:
                    catalog.db.execute('UPDATE shared_events SET uploaded=1 WHERE id=?', (identity,))
            code, listing = self.request(auth, 'PROPFIND', self.root + '/events')
            if code != 207:
                raise MetadataError('Shared event listing failed (HTTP %d).' % code)
            added = []
            for response in ET.fromstring(listing).findall('{DAV:}response'):
                href = response.findtext('{DAV:}href') or ''
                name = urllib.parse.unquote(urllib.parse.urlsplit(href).path).rstrip('/').rsplit('/', 1)[-1]
                if not re.fullmatch(r'\d{20}-[a-f0-9]{32}-[a-f0-9]{32}\.json', name):
                    continue
                identity = name[:-5]
                if identity in known:
                    continue
                data = self.get(auth, self.root + '/events/' + name).decode('utf-8')
                event = json.loads(data)
                self.validate_event(identity, event)
                added.append((identity, data))
            with catalog.lock, catalog.db:
                catalog.db.executemany('INSERT OR IGNORE INTO shared_events VALUES(?,?,1)', added)
                replay = rebuild or any(identity < self.last for identity, _ in added)
                if replay:
                    for table in ('files', 'mtimes'):
                        catalog.remove_subtree(table, self.server.user_scope, self.prefix)
                    self.apply_records(self.base)
                    self.pending = {}
                    self.clock = 0
                    self.last = ''
                    rows = list(catalog.db.execute('SELECT id,data FROM shared_events ORDER BY id'))
                else:
                    rows = list(catalog.db.execute('SELECT id,data FROM shared_events WHERE id>? ORDER BY id', (self.last,)))
                for identity, data in rows:
                    self.apply(json.loads(data))
                    self.last = identity
                self.save_cursor()
            self.next_refresh = time.monotonic() + 5

    def validate_event(self, identity, event):
        if (event.get('version') != 1 or event.get('id') != identity or type(event.get('clock')) is not int
                or event['clock'] < 1 or event.get('kind') not in ('intent', 'commit', 'abort')
                or not identity.startswith('%020d-' % event['clock'])
                or not re.fullmatch(r'[a-f0-9]{32}', event.get('device', ''))):
            raise MetadataError('Invalid shared event identity.')
        if event['kind'] == 'intent':
            if not isinstance(event.get('paths'), list) or not event['paths']:
                raise MetadataError('Invalid shared write intent.')
            for path in event['paths']:
                self.absolute(path)
        else:
            if not isinstance(event.get('resolves'), list):
                raise MetadataError('Invalid shared event resolution.')
            if event['kind'] == 'commit':
                for path in event['clear']:
                    self.absolute(path)
                self.validate_records(event)

    def append(self, auth, kind, **fields):
        catalog = self.server.catalog
        self.clock += 1
        identity = '%020d-%s-%s' % (self.clock, self.device, uuid.uuid4().hex)
        event = {'version': 1, 'id': identity, 'clock': self.clock, 'device': self.device, 'kind': kind, **fields}
        data = self.encode(event).decode('utf-8')
        with catalog.lock, catalog.db:
            catalog.db.execute('INSERT INTO shared_events VALUES(?,?,0)', (identity, data))
        self.next_refresh = 0
        self.put(auth, self.root + '/events/' + identity + '.json', data.encode('utf-8'))
        with catalog.lock, catalog.db:
            catalog.db.execute('UPDATE shared_events SET uploaded=1 WHERE id=?', (identity,))
            self.apply(event)
            self.last = identity
            self.save_cursor()
        self.next_refresh = 0
        return event

    @staticmethod
    def overlaps(left, right):
        return left == right or left.startswith(right + '/') or right.startswith(left + '/') or left == '' or right == ''

    def check(self, paths, own_retry=False):
        relatives = [self.relative(p) for p in paths if self.in_library(p)]
        for event in self.pending.values():
            if own_retry and event['device'] == self.device:
                continue
            if any(self.overlaps(p, old) for p in relatives for old in event['paths']):
                raise MetadataError('Another metadata write needs completion or recovery.')

    def begin(self, auth, paths):
        if not self.enabled:
            return None
        with self.lock:
            self.refresh(auth, force=True)
            self.check(paths, own_retry=True)
            relatives = [self.relative(p) for p in paths]
            old = [identity for identity, event in self.pending.items() if event['device'] == self.device
                   and any(self.overlaps(p, q) for p in relatives for q in event['paths'])]
            intent = self.append(auth, 'intent', paths=relatives)
            return [*old, intent['id']]

    def finish(self, auth, identities, paths, success):
        if identities is None:
            return
        with self.lock:
            if success:
                records = {'files': [], 'mtimes': []}
                for path in paths:
                    current = self.records(path)
                    for key in records:
                        records[key].extend(current[key])
                self.append(auth, 'commit', resolves=identities,
                            clear=[self.relative(p) for p in paths], **records)
            else:
                self.append(auth, 'abort', resolves=identities)

    def status(self):
        return {'enabled': self.enabled, 'ready': self.ready, 'pending': len(self.pending), 'clock': self.clock}
