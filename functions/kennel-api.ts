import { createAdminClient } from 'npm:@insforge/sdk';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Player-Token, X-Host-Token, Idempotency-Key',
  'Cache-Control': 'no-store',
};

type JsonRecord = Record<string, unknown>;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function requiredString(value: unknown, label: string, maxLength = 320) {
  if (typeof value !== 'string' || value.trim().length === 0 || value.length > maxLength) {
    throw new Error(`${label} is required`);
  }
  return value.trim();
}

function optionalString(value: unknown, maxLength = 320) {
  if (value === undefined || value === null || value === '') return '';
  if (typeof value !== 'string' || value.length > maxLength) throw new Error('Invalid text value');
  return value.trim();
}

function requestId(req: Request) {
  const value = req.headers.get('Idempotency-Key');
  if (!value || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new Error('A valid idempotency key is required');
  }
  return value;
}

function randomToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

async function sha256(value: string) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

async function sameSecret(left: string, right: string) {
  const [leftHash, rightHash] = await Promise.all([sha256(left), sha256(right)]);
  let difference = leftHash.length ^ rightHash.length;
  for (let index = 0; index < Math.max(leftHash.length, rightHash.length); index += 1) {
    difference |= (leftHash.charCodeAt(index) || 0) ^ (rightHash.charCodeAt(index) || 0);
  }
  return difference === 0;
}

function createBackend() {
  const baseUrl = Deno.env.get('INSFORGE_BASE_URL') ?? Deno.env.get('INSFORGE_URL');
  const apiKey = Deno.env.get('API_KEY') ?? Deno.env.get('INSFORGE_API_KEY');
  if (!baseUrl || !apiKey) throw new Error('Backend function secrets are not configured');
  return createAdminClient({ baseUrl, apiKey });
}

async function rpc<T>(backend: ReturnType<typeof createBackend>, name: string, args: JsonRecord = {}) {
  const { data, error } = await backend.database.rpc(name, args);
  if (error) throw new Error(error.message || `Server action ${name} failed`);
  return data as T;
}

async function playerHash(req: Request) {
  const token = req.headers.get('X-Player-Token');
  if (!token || token.length < 32 || token.length > 160) throw new Error('Player session is required');
  return sha256(token);
}

async function hostHash(req: Request) {
  const token = req.headers.get('X-Host-Token');
  if (!token || token.length < 32 || token.length > 160) throw new Error('Host session is required');
  return sha256(token);
}

export default async function handler(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  try {
    const body = await req.json() as JsonRecord;
    const action = requiredString(body.action, 'Action', 60);
    const backend = createBackend();

    if (action === 'public_snapshot') {
      return json({ data: await rpc(backend, 'kennel_public_snapshot') });
    }

    if (action === 'join') {
      const nickname = requiredString(body.nickname, 'Nickname', 24);
      const claimEmail = optionalString(body.claimEmail);
      const sessionToken = requiredString(body.sessionToken, 'Session token', 160);
      if (sessionToken.length < 32) throw new Error('Invalid session token');
      return json({
        data: await rpc(backend, 'kennel_join_player', {
          p_nickname: nickname,
          p_claim_email: claimEmail,
          p_token_hash: await sha256(sessionToken),
        }),
      });
    }

    if (action === 'player_snapshot') {
      return json({
        data: await rpc(backend, 'kennel_player_snapshot', {
          p_token_hash: await playerHash(req),
        }),
      });
    }

    if (action === 'host_login') {
      const configuredPin = Deno.env.get('HOST_PIN');
      const pin = requiredString(body.pin, 'PIN', 64);
      if (!configuredPin) throw new Error('Host PIN is not configured');
      if (!(await sameSecret(pin, configuredPin))) return json({ error: 'Incorrect host PIN' }, 401);

      const token = randomToken();
      const expiresAt = new Date(Date.now() + 8 * 60 * 60 * 1000).toISOString();
      const { error } = await backend.database.from('host_sessions').insert([{
        token_hash: await sha256(token),
        expires_at: expiresAt,
      }]);
      if (error) throw new Error(error.message || 'Could not create host session');
      return json({ data: { token, expiresAt } });
    }

    const hostTokenHash = await hostHash(req);

    if (action === 'host_snapshot') {
      return json({ data: await rpc(backend, 'kennel_host_snapshot', { p_host_token_hash: hostTokenHash }) });
    }

    const common = {
      p_host_token_hash: hostTokenHash,
      p_request_id: requestId(req),
    };

    switch (action) {
      case 'record_score':
        return json({ data: await rpc(backend, 'kennel_record_score', {
          ...common,
          p_team: requiredString(body.team, 'Team', 8),
          p_score_type: requiredString(body.scoreType, 'Score type', 8),
        }) });
      case 'undo_latest_score':
        return json({ data: await rpc(backend, 'kennel_undo_latest_score', common) });
      case 'set_pause':
        if (typeof body.paused !== 'boolean') throw new Error('Paused must be true or false');
        return json({ data: await rpc(backend, 'kennel_set_pause', { ...common, p_paused: body.paused }) });
      case 'start_quarter':
        if (!Number.isInteger(body.quarter)) throw new Error('Quarter must be a number');
        return json({ data: await rpc(backend, 'kennel_start_quarter', { ...common, p_quarter: body.quarter }) });
      case 'end_quarter':
        return json({ data: await rpc(backend, 'kennel_end_quarter', common) });
      case 'set_grid': {
        const rowDigits = body.rowDigits;
        const colDigits = body.colDigits;
        if (!Array.isArray(rowDigits) || !Array.isArray(colDigits)) throw new Error('Digit orders are required');
        return json({ data: await rpc(backend, 'kennel_set_grid', {
          ...common,
          p_home_team: requiredString(body.homeTeam, 'Home team', 60),
          p_away_team: requiredString(body.awayTeam, 'Away team', 60),
          p_row_digits: rowDigits,
          p_col_digits: colDigits,
        }) });
      }
      case 'link_purchase':
        return json({ data: await rpc(backend, 'kennel_link_purchase', {
          ...common,
          p_purchase_id: requiredString(body.purchaseId, 'Purchase', 40),
          p_player_id: body.playerId === null ? null : requiredString(body.playerId, 'Player', 40),
        }) });
      default:
        return json({ error: 'Unknown action' }, 404);
    }
  } catch (caught) {
    const message = caught instanceof Error ? caught.message : 'Unexpected server error';
    const unauthorized = /session|required/i.test(message);
    return json({ error: message }, unauthorized ? 401 : 400);
  }
}
