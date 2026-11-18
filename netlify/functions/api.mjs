// Master Ludo backend: one Netlify Function serving /api/*.
// Every player request runs inside a transaction that switches to the
// restricted ludo_app role and sets app.user_id, so Row Level Security and
// the RPC functions in the migration decide what each player may do.
// UNTESTED: written without a live database; verify before merging.

import pg from "pg";
import { Chess } from "chess.js";
import crypto from "node:crypto";

// Supabase Postgres. DATABASE_URL is set in Netlify environment variables (never in code).
const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: /supabase\.(co|com)/.test(process.env.DATABASE_URL ?? "") ? { rejectUnauthorized: false } : false,   // Supabase needs SSL
  max: 5,
});

const json = (status, body) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

const sha256 = (s) => crypto.createHash("sha256").update(s).digest("hex");

function hashPassword(password) {
  const salt = crypto.randomBytes(16);
  const key = crypto.scryptSync(password, salt, 64);
  return `scrypt$${salt.toString("hex")}$${key.toString("hex")}`;
}

function verifyPassword(password, stored) {
  const [, saltHex, keyHex] = stored.split("$");
  const expected = Buffer.from(keyHex, "hex");
  const key = crypto.scryptSync(password, Buffer.from(saltHex, "hex"), 64);
  return key.length === expected.length && crypto.timingSafeEqual(key, expected);
}

// Map database error messages (raised by the migration) to HTTP responses.
const KNOWN_ERRORS = {
  username_taken: 409,
  friend_code_taken: 409,
  invalid_username: 400,
  invalid_friend_code: 400,
  not_authenticated: 401,
  not_friends: 403,
  target_offline: 409,
  rate_limited: 429,
  challenge_expired: 410,
  challenge_already_pending: 409,
  stale_state: 409,
  not_your_turn: 409,
  match_finished: 409,
  match_not_found: 404,
  friend_code_not_found: 404,
  already_friends: 409,
  request_already_sent: 409,
  friend_request_not_found: 404,
  challenge_not_found: 404,
  challenge_not_pending: 409,
  challenge_not_pending_or_not_yours: 404,
  match_not_active_or_not_yours: 404,
  friendship_not_found: 404,
  cannot_add_self: 400,
  cannot_challenge_self: 400,
  invalid_game_type: 400,
};

function errorResponse(e) {
  const msg = String(e?.message ?? e);
  const code = Object.keys(KNOWN_ERRORS).find((k) => msg.includes(k));
  if (code) return json(KNOWN_ERRORS[code], { error: code });
  console.error("unexpected", msg);
  return json(500, { error: "server_error" });
}

// Run fn(client) as the given player inside one transaction.
async function asPlayer(uid, fn) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    await client.query("SET LOCAL ROLE ludo_app");
    await client.query("SELECT set_config('app.user_id', $1, true)", [uid]);
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (e) {
    await client.query("ROLLBACK").catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

// Whitelisted player RPCs: name -> ordered parameter names.
const RPC = {
  heartbeat: [],
  get_my_profile: [],
  find_user_by_username: ["p_username"],
  send_friend_request: ["p_friend_code"],
  respond_friend_request: ["p_requester", "p_accept"],
  remove_friend: ["p_friend"],
  list_friends: [],
  create_challenge: ["p_to_user", "p_game_type"],
  accept_challenge: ["p_challenge_id"],
  decline_challenge: ["p_challenge_id"],
  cancel_challenge: ["p_challenge_id"],
  list_my_challenges: [],
  get_match: ["p_match_id"],
  resign_match: ["p_match_id"],
  set_my_email: ["p_email"],
  list_my_matches: [],
};

async function callRpc(client, name, body) {
  const params = RPC[name];
  const args = params.map((p, i) => `$${i + 1}`).join(", ");
  const values = params.map((p) => body[p.slice(2)] ?? body[p]);
  const { rows } = await client.query(`SELECT * FROM ${name}(${args})`, values);
  return rows;
}

async function authUser(req) {
  const auth = req.headers.get("authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token) return null;
  const { rows } = await pool.query("SELECT resolve_session($1) AS uid", [sha256(token)]);
  return rows[0]?.uid ?? null;
}

// Robot move when a player's 20-second turn has run out. The database checks
// that the time really passed; the server picks a legal move with chess.js.
function robotPick(moves) {
  const checks = moves.filter((m) => m.san && m.san.includes("#"));
  if (checks.length) return checks[0];
  const captures = moves.filter((m) => m.captured);
  const pool = captures.length && Math.random() < 0.7 ? captures : moves;
  return pool[Math.floor(Math.random() * pool.length)];
}

async function handleTimeout(uid, body) {
  const { match_id } = body;
  return asPlayer(uid, async (client) => {
    const { rows } = await client.query("SELECT * FROM get_match($1)", [match_id]);
    const m = rows[0];
    if (!m) throw new Error("match_not_found");
    if (m.game_type !== "chess") throw new Error("invalid_game_type");
    if (m.status !== "active") throw new Error("match_finished");

    const chess = new Chess(m.state.fen);
    const moves = chess.moves({ verbose: true });
    if (!moves.length) throw new Error("no_moves");
    const mover = chess.turn();
    const pick = robotPick(moves);
    const applied = chess.move({ from: pick.from, to: pick.to, promotion: pick.promotion });
    let result = null;
    if (chess.isCheckmate()) result = mover === "w" ? "white" : "black";
    else if (chess.isDraw() || chess.isStalemate()) result = "draw";

    const newState = { fen: chess.fen(), turn: chess.turn() };
    const { rows: out } = await client.query(
      "SELECT * FROM apply_robot_move($1, $2, $3::jsonb, $4::jsonb, $5)",
      [match_id, m.version, JSON.stringify(applied), JSON.stringify(newState), result],
    );
    return out[0];
  });
}

// Chess move validation on the server. The client sends only the move;
// the server replays it with chess.js and computes the new state.
async function handleMove(uid, body) {
  const { match_id, expected_version, move } = body;
  return asPlayer(uid, async (client) => {
    const { rows } = await client.query("SELECT * FROM get_match($1)", [match_id]);
    const m = rows[0];
    if (!m) throw new Error("match_not_found");
    if (m.game_type !== "chess") throw new Error("invalid_game_type");
    if (m.status !== "active") throw new Error("match_finished");

    const chess = new Chess(m.state.fen);
    const mover = chess.turn();
    const applied = chess.move(move); // throws on an illegal move
    if (!applied) throw new Error("illegal_move");

    let result = null;
    if (chess.isCheckmate()) result = mover === "w" ? "white" : "black";
    else if (chess.isDraw() || chess.isStalemate()) result = "draw";

    const newState = { fen: chess.fen(), turn: chess.turn() };
    const { rows: out } = await client.query(
      "SELECT * FROM make_move($1, $2, $3::jsonb, $4::jsonb, $5)",
      [match_id, expected_version, JSON.stringify(applied), JSON.stringify(newState), result],
    );
    return out[0];
  });
}

export default async (req) => {
  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/api\/?/, "");
  if (req.method !== "POST" && req.method !== "GET") return json(405, { error: "method" });

  try {
    if (path === "signup" && req.method === "POST") {
      const { username, password, friend_code } = await req.json();
      if (typeof password !== "string" || password.length < 6) {
        return json(400, { error: "weak_password" });
      }
      const { rows } = await pool.query("SELECT sign_up($1, $2, $3) AS id",
        [username, friend_code, hashPassword(password)]);
      return json(201, { user_id: rows[0].id });
    }

    if (path === "login" && req.method === "POST") {
      const { username, password } = await req.json();
      const { rows } = await pool.query("SELECT * FROM get_login($1)", [String(username ?? "")]);
      const row = rows[0];
      // Same response whether the user is missing or the password is wrong.
      const ok = row && typeof password === "string" && verifyPassword(password, row.password_hash);
      if (!ok) return json(401, { error: "invalid_credentials" });
      const token = crypto.randomBytes(32).toString("base64url");
      await pool.query("SELECT create_session($1, $2)", [row.user_id, sha256(token)]);
      return json(200, { token });
    }

    if (path === "logout" && req.method === "POST") {
      const auth = req.headers.get("authorization") ?? "";
      const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
      if (token) await pool.query("SELECT delete_session($1)", [sha256(token)]);
      return json(200, { ok: true });
    }

    // Everything below needs a logged-in player.
    const uid = await authUser(req);
    if (!uid) return json(401, { error: "not_authenticated" });

    if (path === "move" && req.method === "POST") {
      return json(200, await handleMove(uid, await req.json()));
    }

    if (path === "timeout" && req.method === "POST") {
      return json(200, await handleTimeout(uid, await req.json()));
    }

    if (path.startsWith("rpc/") && req.method === "POST") {
      const name = path.slice(4);
      if (!(name in RPC)) return json(404, { error: "unknown_rpc" });
      const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
      const rows = await asPlayer(uid, (client) => callRpc(client, name, body));
      return json(200, rows);
    }

    return json(404, { error: "not_found" });
  } catch (e) {
    return errorResponse(e);
  }
};

export const config = { path: "/api/*" };
