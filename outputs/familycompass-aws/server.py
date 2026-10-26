#!/usr/bin/env python3
"""Private Family Compass encrypted signaling relay. No media recording."""
import base64
import hashlib
import hmac
import json
import os
import re
import sqlite3
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

DB = os.environ.get('FC_DB', '/var/lib/familycompass/mailboxes.sqlite3')
APP_KEY = os.environ['FC_RELAY_KEY']
TURN_SECRET = os.environ['FC_TURN_SECRET']
TURN_HOST = os.environ['FC_TURN_HOST']
ROUTE = re.compile(r'^/v1/rooms/([a-f0-9]{64})/(parent|child|ice-servers|activity|status)$')
AUTH = re.compile(r'^Bearer ([a-f0-9]{64})$')
MAX_BODY = 50_000

@contextmanager
def database():
    db = sqlite3.connect(DB, timeout=5)
    db.execute('PRAGMA busy_timeout=5000')
    db.execute('PRAGMA secure_delete=ON')
    try:
        with db:
            yield db
    finally:
        db.close()

with database() as db:
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('CREATE TABLE IF NOT EXISTS mailboxes (room TEXT, role TEXT, body TEXT, updated REAL, expires REAL, PRIMARY KEY(room,role))')
    db.execute('CREATE TABLE IF NOT EXISTS activity (seq INTEGER PRIMARY KEY AUTOINCREMENT, room TEXT NOT NULL, id TEXT NOT NULL, created INTEGER NOT NULL, expires REAL NOT NULL, body TEXT NOT NULL, UNIQUE(room,id))')
    db.execute('CREATE INDEX IF NOT EXISTS activity_room_seq ON activity(room,seq)')
    db.execute('CREATE INDEX IF NOT EXISTS activity_expiry ON activity(expires)')

def expire_records():
    while True:
        try:
            with database() as db:
                db.execute('DELETE FROM activity WHERE expires<=?', (time.time(),))
                db.execute('DELETE FROM mailboxes WHERE expires<=?', (time.time(),))
            # Retire old WAL pages too; readers always exclude expired rows.
            with database() as db:
                db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        except sqlite3.Error:
            print('expiry_cleanup_retry', flush=True)
        time.sleep(60)

class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 32
    slots = threading.BoundedSemaphore(32)
    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise
    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'FamilyCompass'
    sys_version = ''
    def setup(self):
        super().setup()
        self.connection.settimeout(15)
    def log_message(self, *args):
        pass  # Never log room identifiers, headers, credentials or envelopes.
    def reply(self, status, body=None):
        payload = b'' if body is None else json.dumps(body, separators=(',', ':')).encode()
        self.send_response(status)
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store, private')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True
        if payload:
            self.wfile.write(payload)
    def do_GET(self):
        self.dispatch()
    def do_PUT(self):
        self.dispatch()
    def dispatch(self):
        try:
            self.handle_request()
        except (ConnectionError, TimeoutError):
            self.close_connection = True
        except Exception as error:
            print('relay_error=' + type(error).__name__, flush=True)
            try:
                self.reply(503, {'error': 'Relay temporarily unavailable'})
            except OSError:
                pass
    def handle_request(self):
        path = urlsplit(self.path).path
        if path == '/health' and self.command == 'GET':
            self.reply(200, {'ok': True, 'service': 'familycompass', 'version': '1.2.0', 'turn': True})
            return
        match = ROUTE.fullmatch(path)
        auth = AUTH.fullmatch(self.headers.get('Authorization', ''))
        key = self.headers.get('X-Family-Compass-Client', '')
        if not match or not auth or not hmac.compare_digest(key, APP_KEY):
            self.reply(404, {'error': 'Not found'})
            return
        room, role = match.groups()
        expected = hashlib.sha256(('familycompass-room-v1:' + auth[1]).encode()).hexdigest()
        if not hmac.compare_digest(room, expected):
            self.reply(404, {'error': 'Not found'})
            return
        now = time.time()
        if role == 'activity':
            self.activity(room, now)
            return
        if role == 'ice-servers':
            if self.command != 'GET':
                self.reply(405)
                return
            username = str(int(now) + 14_400) + ':' + room[:24]
            credential = base64.b64encode(hmac.new(TURN_SECRET.encode(), username.encode(), hashlib.sha1).digest()).decode()
            self.reply(200, {'iceServers': [
                {'urls': 'stun:' + TURN_HOST + ':3478'},
                {'urls': ['turn:' + TURN_HOST + ':3478?transport=udp', 'turn:' + TURN_HOST + ':3478?transport=tcp'],
                 'username': username, 'credential': credential},
            ]})
            return
        if self.command == 'GET':
            with database() as db:
                row = db.execute('SELECT body FROM mailboxes WHERE room=? AND role=? AND expires>?', (room, role, now)).fetchone()
            self.reply(200, json.loads(row[0])) if row else self.reply(204)
            return
        try:
            size = int(self.headers.get('Content-Length', '-1'))
        except ValueError:
            size = -1
        if size <= 0 or size > MAX_BODY or self.headers.get('Transfer-Encoding'):
            self.reply(413, {'error': 'Invalid request size'})
            return
        try:
            raw = self.rfile.read(size)
            if len(raw) != size:
                raise ValueError('Truncated body')
            envelope = json.loads(raw)
            if not isinstance(envelope, dict) or envelope.get('v') != 1:
                raise ValueError('Invalid version')
            for field, low, high in [('nonce', 12, 12), ('mac', 16, 16), ('ciphertext', 1, 32768)]:
                if not isinstance(envelope.get(field), str):
                    raise ValueError('Invalid field')
                decoded = base64.b64decode(envelope[field], validate=True)
                if not low <= len(decoded) <= high:
                    raise ValueError('Invalid length')
            body = json.dumps({key: envelope[key] for key in ('v', 'nonce', 'ciphertext', 'mac')})
        except (ValueError, TypeError):
            self.reply(400, {'error': 'Invalid encrypted envelope'})
            return
        with database() as db:
            db.execute('BEGIN IMMEDIATE')
            db.execute('DELETE FROM mailboxes WHERE expires<=?', (now,))
            row = db.execute('SELECT updated FROM mailboxes WHERE room=? AND role=?', (room, role)).fetchone()
            if row and now - row[0] < 0.2:
                self.reply(429, {'error': 'Too many updates'})
                return
            if not row and db.execute('SELECT count(*) FROM mailboxes').fetchone()[0] >= 2048:
                self.reply(503, {'error': 'Relay at capacity'})
                return
            db.execute('INSERT INTO mailboxes VALUES(?,?,?,?,?) ON CONFLICT(room,role) DO UPDATE SET body=excluded.body,updated=excluded.updated,expires=excluded.expires',
                       (room, role, body, now, now + (60 if role == 'status' else 3600)))
        self.reply(204)

    def activity(self, room, now):
        if self.command == 'GET':
            try:
                after = int(parse_qs(urlsplit(self.path).query).get('after', ['0'])[0])
                if not 0 <= after <= 9_223_372_036_854_775_807:
                    raise ValueError()
            except (ValueError, IndexError):
                self.reply(400, {'error': 'Invalid cursor'})
                return
            with database() as db:
                rows = db.execute('SELECT seq,id,created,body FROM activity WHERE room=? AND seq>? AND expires>? ORDER BY seq LIMIT 51', (room, after, now)).fetchall()
            self.reply(200, {'events': [dict(seq=r[0], id=r[1], createdAt=r[2], envelope=json.loads(r[3])) for r in rows[:50]], 'hasMore': len(rows) > 50})
            return
        try:
            size = int(self.headers.get('Content-Length', '-1'))
            if not 0 < size <= MAX_BODY or self.headers.get('Transfer-Encoding'):
                raise ValueError()
            raw = self.rfile.read(size)
            if len(raw) != size:
                raise ValueError()
            events = json.loads(raw)['events']
            if not isinstance(events, list) or not 1 <= len(events) <= 25:
                raise ValueError()
            records = []
            for event in events:
                event_id, created, envelope = event['id'], event['createdAt'], event['envelope']
                if not isinstance(event_id, str) or not re.fullmatch('[a-f0-9]{64}', event_id):
                    raise ValueError()
                if type(created) is not int or not 0 < created <= int((now + 60) * 1000):
                    raise ValueError()
                if not isinstance(envelope, dict) or envelope.get('v') != 1:
                    raise ValueError()
                for field, low, high in [('nonce', 12, 12), ('mac', 16, 16), ('ciphertext', 1, 4096)]:
                    if not isinstance(envelope.get(field), str):
                        raise ValueError()
                    if not low <= len(base64.b64decode(envelope[field], validate=True)) <= high:
                        raise ValueError()
                if created / 1000 + 86400 > now:
                    clean = {k: envelope[k] for k in ('v', 'nonce', 'ciphertext', 'mac')}
                    records.append((room, event_id, created, created / 1000 + 86400, json.dumps(clean)))
        except (ValueError, TypeError, KeyError):
            self.reply(400, {'error': 'Invalid activity batch or device clock'})
            return
        with database() as db:
            db.execute('BEGIN IMMEDIATE')
            db.execute('DELETE FROM activity WHERE expires<=?', (now,))
            room_count = db.execute('SELECT count(*) FROM activity WHERE room=?', (room,)).fetchone()[0]
            total = db.execute('SELECT count(*) FROM activity').fetchone()[0]
            fresh = sum(not db.execute('SELECT 1 FROM activity WHERE room=? AND id=?', r[:2]).fetchone() for r in records)
            if room_count + fresh > 20000 or total + fresh > 100000:
                self.reply(429, {'error': 'Activity capacity reached; retry later'})
                return
            db.executemany('INSERT OR IGNORE INTO activity(room,id,created,expires,body) VALUES(?,?,?,?,?)', records)
        self.reply(204)

if __name__ == '__main__':
    print('Family Compass relay listening on loopback', flush=True)
    threading.Thread(target=expire_records, daemon=True).start()
    Server(('127.0.0.1', 8080), Handler).serve_forever()
