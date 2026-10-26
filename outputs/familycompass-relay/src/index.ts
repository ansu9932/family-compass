interface Env {
  DB: D1Database;
  TURN_KEY_ID?: string;
  TURN_API_TOKEN?: string;
}
interface Envelope { v: 1; nonce: string; ciphertext: string; mac: string }

const HOUR = 60 * 60;
const MAX_BODY = 50_000;
const MAX_CIPHER_BYTES = 32_768;
const HEX_64 = /^[a-f0-9]{64}$/;
const B64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

function response(status: number, body: unknown = null): Response {
  const headers = new Headers({
    'Cache-Control': 'no-store, private',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
  });
  if (body === null) return new Response(null, { status, headers });
  headers.set('Content-Type', 'application/json; charset=utf-8');
  return new Response(JSON.stringify(body), { status, headers });
}

async function readLimited(request: Request): Promise<string | null> {
  if (!request.body) return null;
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_BODY) {
        await reader.cancel();
        return null;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const all = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { all.set(chunk, offset); offset += chunk.byteLength; }
  return new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(all);
}

function validEnvelope(value: unknown): value is Envelope {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const item = value as Record<string, unknown>;
  if (item.v !== 1 || typeof item.nonce !== 'string' || typeof item.ciphertext !== 'string' || typeof item.mac !== 'string') return false;
  if (!B64.test(item.nonce) || !B64.test(item.ciphertext) || !B64.test(item.mac)) return false;
  try {
    return atob(item.nonce).length === 12 && atob(item.mac).length === 16 &&
      atob(item.ciphertext).length <= MAX_CIPHER_BYTES && atob(item.ciphertext).length > 0;
  } catch { return false; }
}

async function authorized(request: Request, roomId: string): Promise<boolean> {
  const match = /^Bearer ([a-f0-9]{64})$/.exec(request.headers.get('Authorization') ?? '');
  if (!match) return false;
  const digest = await crypto.subtle.digest(
    'SHA-256', new TextEncoder().encode(`familycompass-room-v1:${match[1]}`),
  );
  const expected = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return expected === roomId;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === '/health' && request.method === 'GET') return response(200, { ok: true });
    const iceMatch = /^\/v1\/rooms\/([a-f0-9]{64})\/ice-servers$/.exec(url.pathname);
    if (iceMatch && request.method === 'GET') {
      const [, roomId] = iceMatch;
      if (!(await authorized(request, roomId))) return response(404, { error: 'Not found' });
      if (!env.TURN_KEY_ID || !env.TURN_API_TOKEN) {
        return response(200, { iceServers: [{ urls: 'stun:stun.cloudflare.com:3478' }] });
      }
      const credentials = await fetch(
        `https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(env.TURN_KEY_ID)}/credentials/generate-ice-servers`,
        {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${env.TURN_API_TOKEN}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ ttl: 14_400 }),
        },
      );
      if (!credentials.ok) return response(503, { error: 'TURN credentials are unavailable' });
      const configuration = await credentials.json() as { iceServers?: unknown };
      if (!Array.isArray(configuration.iceServers) || configuration.iceServers.length === 0) {
        return response(503, { error: 'TURN provider returned no ICE servers' });
      }
      return response(200, { iceServers: configuration.iceServers });
    }
    const match = /^\/v1\/rooms\/([a-f0-9]{64})\/(parent|child)$/.exec(url.pathname);
    if (!match) return response(404, { error: 'Not found' });
    if (request.method !== 'GET' && request.method !== 'PUT') return response(405, { error: 'Method not allowed' });
    const [, roomId, mailbox] = match;
    if (!(await authorized(request, roomId))) return response(404, { error: 'Not found' });
    const now = Math.floor(Date.now() / 1000);
    if (request.method === 'GET') {
      const row = await env.DB.prepare('SELECT envelope FROM mailboxes WHERE room_id = ? AND mailbox = ? AND expires_at > ?')
        .bind(roomId, mailbox, now).first<{ envelope: string }>();
      return row ? response(200, JSON.parse(row.envelope)) : response(204);
    }
    const length = Number(request.headers.get('Content-Length') ?? 0);
    if (length > MAX_BODY) return response(413, { error: 'Request too large' });
    let value: unknown;
    try {
      const text = await readLimited(request);
      if (text === null) return response(413, { error: 'Request too large' });
      value = JSON.parse(text);
    } catch { return response(400, { error: 'Invalid JSON' }); }
    if (!validEnvelope(value)) return response(400, { error: 'Invalid encrypted envelope' });
    const latest = await env.DB.prepare('SELECT updated_at FROM mailboxes WHERE room_id = ? AND mailbox = ?')
      .bind(roomId, mailbox).first<{ updated_at: number }>();
    if (latest && now - latest.updated_at < 1) return response(429, { error: 'Too many updates' });
    await env.DB.prepare(`INSERT INTO mailboxes (room_id, mailbox, envelope, expires_at, updated_at)
      VALUES (?, ?, ?, ?, ?) ON CONFLICT(room_id, mailbox) DO UPDATE SET
      envelope = excluded.envelope, expires_at = excluded.expires_at, updated_at = excluded.updated_at`)
      .bind(roomId, mailbox, JSON.stringify(value), now + HOUR, now).run();
    return response(204);
  },
  async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
    await env.DB.prepare('DELETE FROM mailboxes WHERE expires_at <= ?').bind(Math.floor(Date.now() / 1000)).run();
  },
} satisfies ExportedHandler<Env>;
