-- ============================================================
-- Master Ludo – accounts, friends, presence, challenges, matches
-- ============================================================

-- Restricted role the API server switches to for every request.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ludo_app') THEN
    CREATE ROLE ludo_app NOLOGIN;
  END IF;
END $$;
GRANT ludo_app TO CURRENT_USER;
GRANT USAGE ON SCHEMA public TO ludo_app;

-- Current player, set per transaction by the server after token verification.
CREATE OR REPLACE FUNCTION app_uid() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.user_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION require_uid() RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE v uuid := app_uid();
BEGIN
  IF v IS NULL THEN RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '28000'; END IF;
  RETURN v;
END $$;

-- ---------- Accounts ----------
CREATE TABLE profiles (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username    text NOT NULL CHECK (username ~ '^[A-Za-z0-9_]{3,20}$'),
  friend_code text NOT NULL CHECK (friend_code ~ '^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$'),
  created_at  timestamptz NOT NULL DEFAULT now(),
  is_online   boolean NOT NULL DEFAULT false,
  last_seen   timestamptz
);
CREATE UNIQUE INDEX profiles_username_ci_uq ON profiles (lower(username));
CREATE UNIQUE INDEX profiles_friend_code_uq ON profiles (friend_code);
CREATE INDEX profiles_last_seen_idx ON profiles (last_seen);

-- Auth data: server-only, never granted to ludo_app.
CREATE TABLE credentials (
  user_id       uuid PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
  password_hash text NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE sessions (
  token_hash  text PRIMARY KEY,               -- sha256 of the bearer token
  user_id     uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL DEFAULT now() + interval '30 days'
);
CREATE INDEX sessions_user_idx ON sessions (user_id);

-- ---------- Friends ----------
CREATE TABLE friendships (
  user_a     uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,  -- requester
  user_b     uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,  -- addressee
  status     text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_a, user_b),
  CHECK (user_a <> user_b)
);
CREATE UNIQUE INDEX friendships_pair_uq ON friendships (LEAST(user_a,user_b), GREATEST(user_a,user_b));
CREATE INDEX friendships_user_b_idx ON friendships (user_b);

-- ---------- Challenges ----------
CREATE TABLE challenges (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_user  uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  to_user    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  game_type  text NOT NULL CHECK (game_type IN ('robot_ai','friends','chess')),
  status     text NOT NULL DEFAULT 'pending'
             CHECK (status IN ('pending','accepted','declined','cancelled','expired')),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT now() + interval '30 seconds',
  CHECK (from_user <> to_user),
  CHECK (expires_at = created_at + interval '30 seconds')
);
CREATE INDEX challenges_from_created_idx ON challenges (from_user, created_at DESC);
CREATE INDEX challenges_to_status_idx ON challenges (to_user, status);
CREATE INDEX challenges_pending_exp_idx ON challenges (expires_at) WHERE status = 'pending';

-- ---------- Matches ----------
CREATE TABLE matches (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  challenge_id uuid UNIQUE REFERENCES challenges(id) ON DELETE SET NULL,
  player_white uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  player_black uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  game_type    text NOT NULL CHECK (game_type IN ('robot_ai','friends','chess')),
  state        jsonb NOT NULL DEFAULT '{}'::jsonb,   -- e.g. {"fen": "...", "turn": "w", "moves": [...]}
  version      integer NOT NULL DEFAULT 0,          -- optimistic lock for moves
  status       text NOT NULL DEFAULT 'active' CHECK (status IN ('active','finished')),
  winner       uuid REFERENCES profiles(id),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX matches_white_idx ON matches (player_white, status);
CREATE INDEX matches_black_idx ON matches (player_black, status);

-- ============================================================
-- Row Level Security (enabled on every table)
-- ============================================================
ALTER TABLE profiles    ENABLE ROW LEVEL SECURITY;
ALTER TABLE credentials ENABLE ROW LEVEL SECURITY;  -- no policies: invisible to ludo_app
ALTER TABLE sessions    ENABLE ROW LEVEL SECURITY;  -- no policies: invisible to ludo_app
ALTER TABLE friendships ENABLE ROW LEVEL SECURITY;
ALTER TABLE challenges  ENABLE ROW LEVEL SECURITY;
ALTER TABLE matches     ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION are_friends(a uuid, b uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM friendships
                 WHERE status = 'accepted'
                   AND ((user_a = a AND user_b = b) OR (user_a = b AND user_b = a)))
$$;

-- Read-only access; all writes go through RPC functions.
REVOKE ALL ON profiles, credentials, sessions, friendships, challenges, matches FROM PUBLIC, ludo_app;
GRANT SELECT (id, username, friend_code, is_online, last_seen, created_at) ON profiles TO ludo_app;
GRANT SELECT ON friendships, challenges, matches TO ludo_app;

CREATE POLICY profiles_self_or_friend ON profiles FOR SELECT TO ludo_app
  USING (id = app_uid() OR are_friends(app_uid(), id));
CREATE POLICY friendships_involved ON friendships FOR SELECT TO ludo_app
  USING (app_uid() IN (user_a, user_b));
CREATE POLICY challenges_involved ON challenges FOR SELECT TO ludo_app
  USING (app_uid() IN (from_user, to_user));
CREATE POLICY matches_participant ON matches FOR SELECT TO ludo_app
  USING (app_uid() IN (player_white, player_black));

-- ============================================================
-- Helpers
-- ============================================================
CREATE OR REPLACE FUNCTION online_cutoff() RETURNS timestamptz
LANGUAGE sql STABLE AS $$ SELECT now() - interval '60 seconds' $$;

CREATE OR REPLACE FUNCTION expire_stale_challenges() RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE challenges SET status = 'expired'
  WHERE status = 'pending' AND expires_at <= now();
  UPDATE profiles SET is_online = false
  WHERE is_online AND (last_seen IS NULL OR last_seen < online_cutoff());
$$;

-- ============================================================
-- Server-only auth RPCs (called by the server WITHOUT switching role)
-- ============================================================
CREATE OR REPLACE FUNCTION sign_up(p_username text, p_friend_code text, p_password_hash text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_code text := upper(trim(p_friend_code));
BEGIN
  IF p_username !~ '^[A-Za-z0-9_]{3,20}$' THEN
    RAISE EXCEPTION 'invalid_username: 3-20 letters, digits or underscore' USING ERRCODE = '22023';
  END IF;
  IF v_code !~ '^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$' THEN
    RAISE EXCEPTION 'invalid_friend_code: format XXXX-XXXX, no 0/O/1/I' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM profiles WHERE lower(username) = lower(p_username)) THEN
    RAISE EXCEPTION 'username_taken' USING ERRCODE = '23505';
  END IF;
  IF EXISTS (SELECT 1 FROM profiles WHERE friend_code = v_code) THEN
    RAISE EXCEPTION 'friend_code_taken' USING ERRCODE = '23505';
  END IF;
  INSERT INTO profiles (username, friend_code) VALUES (p_username, v_code) RETURNING id INTO v_id;
  INSERT INTO credentials (user_id, password_hash) VALUES (v_id, p_password_hash);
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN  -- race between the checks and the insert
  IF SQLERRM LIKE '%username%' THEN RAISE EXCEPTION 'username_taken' USING ERRCODE = '23505';
  ELSE RAISE EXCEPTION 'friend_code_taken' USING ERRCODE = '23505'; END IF;
END $$;

CREATE OR REPLACE FUNCTION get_login(p_username text)
RETURNS TABLE (user_id uuid, password_hash text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id, c.password_hash FROM profiles p JOIN credentials c ON c.user_id = p.id
  WHERE lower(p.username) = lower(p_username)
$$;

CREATE OR REPLACE FUNCTION create_session(p_user_id uuid, p_token_hash text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO sessions (token_hash, user_id) VALUES (p_token_hash, p_user_id);
  DELETE FROM sessions WHERE user_id = p_user_id AND expires_at < now();
$$;

CREATE OR REPLACE FUNCTION resolve_session(p_token_hash text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT user_id FROM sessions WHERE token_hash = p_token_hash AND expires_at > now()
$$;

CREATE OR REPLACE FUNCTION delete_session(p_token_hash text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  DELETE FROM sessions WHERE token_hash = p_token_hash
$$;

REVOKE EXECUTE ON FUNCTION sign_up(text,text,text), get_login(text), create_session(uuid,text),
  resolve_session(text), delete_session(text) FROM PUBLIC, ludo_app;

-- ============================================================
-- Player RPCs (called as ludo_app with app.user_id set)
-- ============================================================

-- Presence
CREATE OR REPLACE FUNCTION heartbeat() RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := require_uid(); v_now timestamptz := now();
BEGIN
  UPDATE profiles SET last_seen = v_now, is_online = true WHERE id = v_uid;
  RETURN v_now;
END $$;

CREATE OR REPLACE FUNCTION get_my_profile()
RETURNS TABLE (id uuid, username text, friend_code text, is_online boolean, last_seen timestamptz, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT id, username, friend_code, (last_seen >= online_cutoff()), last_seen, created_at
  FROM profiles WHERE id = require_uid()
$$;

-- Exact username search only (case-insensitive exact match, no partial search)
CREATE OR REPLACE FUNCTION find_user_by_username(p_username text)
RETURNS TABLE (id uuid, username text, friend_code text, is_online boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id, p.username, p.friend_code, (p.last_seen >= online_cutoff())
  FROM profiles p
  WHERE require_uid() IS NOT NULL AND lower(p.username) = lower(p_username)
$$;

-- Friends
CREATE OR REPLACE FUNCTION send_friend_request(p_friend_code text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := require_uid(); v_target uuid; v_row friendships;
BEGIN
  SELECT id INTO v_target FROM profiles WHERE friend_code = upper(trim(p_friend_code));
  IF v_target IS NULL THEN RAISE EXCEPTION 'friend_code_not_found' USING ERRCODE = 'P0002'; END IF;
  IF v_target = v_uid THEN RAISE EXCEPTION 'cannot_add_self' USING ERRCODE = '22023'; END IF;

  SELECT * INTO v_row FROM friendships
  WHERE (user_a = v_uid AND user_b = v_target) OR (user_a = v_target AND user_b = v_uid) FOR UPDATE;

  IF FOUND THEN
    IF v_row.status = 'accepted' THEN RAISE EXCEPTION 'already_friends' USING ERRCODE = '23505'; END IF;
    IF v_row.user_a = v_uid THEN RAISE EXCEPTION 'request_already_sent' USING ERRCODE = '23505'; END IF;
    -- They had already invited me: adding their code accepts it.
    UPDATE friendships SET status = 'accepted' WHERE user_a = v_target AND user_b = v_uid;
    RETURN 'accepted';
  END IF;

  INSERT INTO friendships (user_a, user_b) VALUES (v_uid, v_target);
  RETURN 'pending';
END $$;

CREATE OR REPLACE FUNCTION respond_friend_request(p_requester uuid, p_accept boolean) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := require_uid();
BEGIN
  IF p_accept THEN
    UPDATE friendships SET status = 'accepted'
    WHERE user_a = p_requester AND user_b = v_uid AND status = 'pending';
  ELSE
    DELETE FROM friendships WHERE user_a = p_requester AND user_b = v_uid AND status = 'pending';
  END IF;
  IF NOT FOUND THEN RAISE EXCEPTION 'friend_request_not_found' USING ERRCODE = 'P0002'; END IF;
  RETURN CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END;
END $$;

CREATE OR REPLACE FUNCTION remove_friend(p_friend uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := require_uid();
BEGIN
  DELETE FROM friendships
  WHERE (user_a = v_uid AND user_b = p_friend) OR (user_a = p_friend AND user_b = v_uid);
  IF NOT FOUND THEN RAISE EXCEPTION 'friendship_not_found' USING ERRCODE = 'P0002'; END IF;
END $$;

-- Friends + incoming/outgoing requests, with basic info only
CREATE OR REPLACE FUNCTION list_friends()
RETURNS TABLE (user_id uuid, username text, friend_code text, is_online boolean,
               status text, direction text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id, p.username, p.friend_code, (p.last_seen >= online_cutoff()), f.status,
         CASE WHEN f.status = 'accepted' THEN 'friend'
              WHEN f.user_a = require_uid() THEN 'outgoing' ELSE 'incoming' END,
         f.created_at
  FROM friendships f
  JOIN profiles p ON p.id = CASE WHEN f.user_a = require_uid() THEN f.user_b ELSE f.user_a END
  WHERE require_uid() IN (f.user_a, f.user_b)
  ORDER BY f.status, p.username
$$;

-- Challenges
CREATE OR REPLACE FUNCTION create_challenge(p_to_user uuid, p_game_type text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := require_uid(); v_id uuid; v_now timestamptz := now();
BEGIN
  PERFORM expire_stale_challenges();
  IF p_game_type NOT IN ('robot_ai','friends','chess') THEN
    RAISE EXCEPTION 'invalid_game_type' USING ERRCODE = '22023';
  END IF;
  IF p_to_user = v_uid THEN RAISE EXCEPTION 'cannot_challenge_self' USING ERRCODE = '22023'; END IF;
  IF NOT are_friends(v_uid, p_to_user) THEN RAISE EXCEPTION 'not_friends' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_to_user AND last_seen >= online_cutoff()) THEN
    RAISE EXCEPTION 'target_offline' USING ERRCODE = 'P0001';
  END IF;

  -- Serialize per sender so the hourly limit can't be raced.
  PERFORM pg_advisory_xact_lock(hashtext('challenge:' || v_uid::text));
  IF (SELECT count(*) FROM challenges
      WHERE from_user = v_uid AND created_at > v_now - interval '1 hour') >= 10 THEN
    RAISE EXCEPTION 'rate_limited: max 10 challenges per hour' USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM challenges WHERE from_user = v_uid AND to_user = p_to_user
             AND status = 'pending' AND expires_at > v_now) THEN
    RAISE EXCEPTION 'challenge_already_pending' USING ERRCODE = '23505';
  END IF;

  INSERT INTO challenges (from_user, to_user, game_type, created_at, expires_at)
  VALUES (v_uid, p_to_user, p_game_type, v_now, v_now + interval '30 seconds')
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Only the recipient can accept; expired challenges are refused.
CREATE OR REPLACE FUNCTION accept_challenge(p_challenge_id uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := require_uid(); c challenges; v_match uuid; v_state jsonb;
BEGIN
  SELECT * INTO c FROM challenges WHERE id = p_challenge_id FOR UPDATE;
  IF NOT FOUND OR c.to_user <> v_uid THEN RAISE EXCEPTION 'challenge_not_found' USING ERRCODE = 'P0002'; END IF;
  IF c.status = 'pending' AND c.expires_at <= now() THEN
    UPDATE challenges SET status = 'expired' WHERE id = c.id;
    RAISE EXCEPTION 'challenge_expired' USING ERRCODE = 'P0001';
  END IF;
  IF c.status <> 'pending' THEN RAISE EXCEPTION 'challenge_not_pending: %', c.status USING ERRCODE = 'P0001'; END IF;

  UPDATE challenges SET status = 'accepted' WHERE id = c.id;

  v_state := CASE WHEN c.game_type = 'chess'
    THEN jsonb_build_object('fen','rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
                            'turn','w','moves','[]'::jsonb)
    ELSE jsonb_build_object('turn','w','moves','[]'::jsonb) END;

  -- Challenger plays white.
  INSERT INTO matches (challenge_id, player_white, player_black, game_type, state)
  VALUES (c.id, c.from_user, c.to_user, c.game_type, v_state)
  RETURNING id INTO v_match;
  RETURN v_match;
END $$;

-- Only the recipient can decline.
CREATE OR REPLACE FUNCTION decline_challenge(p_challenge_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM expire_stale_challenges();
  UPDATE challenges SET status = 'declined'
  WHERE id = p_challenge_id AND to_user = require_uid() AND status = 'pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'challenge_not_pending_or_not_yours' USING ERRCODE = 'P0002'; END IF;
END $$;

-- Only the sender can cancel.
CREATE OR REPLACE FUNCTION cancel_challenge(p_challenge_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM expire_stale_challenges();
  UPDATE challenges SET status = 'cancelled'
  WHERE id = p_challenge_id AND from_user = require_uid() AND status = 'pending';
  IF NOT FOUND THEN RAISE EXCEPTION 'challenge_not_pending_or_not_yours' USING ERRCODE = 'P0002'; END IF;
END $$;

CREATE OR REPLACE FUNCTION list_my_challenges()
RETURNS SETOF challenges
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM expire_stale_challenges();
  RETURN QUERY SELECT * FROM challenges
    WHERE require_uid() IN (from_user, to_user) AND created_at > now() - interval '1 hour'
    ORDER BY created_at DESC;
END $$;

-- Matches
CREATE OR REPLACE FUNCTION get_match(p_match_id uuid) RETURNS SETOF matches
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM matches WHERE id = p_match_id AND require_uid() IN (player_white, player_black)
$$;

-- The server validates move legality (chess.js) and computes p_new_state.
-- This function checks participation, turn, active status and version.
CREATE OR REPLACE FUNCTION make_move(p_match_id uuid, p_expected_version integer, p_move jsonb,
                                     p_new_state jsonb, p_result text DEFAULT NULL)
RETURNS matches
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := require_uid(); m matches; v_color text;
BEGIN
  SELECT * INTO m FROM matches WHERE id = p_match_id FOR UPDATE;
  IF NOT FOUND OR v_uid NOT IN (m.player_white, m.player_black) THEN
    RAISE EXCEPTION 'match_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF m.status <> 'active' THEN RAISE EXCEPTION 'match_finished' USING ERRCODE = 'P0001'; END IF;
  IF m.version <> p_expected_version THEN RAISE EXCEPTION 'stale_state' USING ERRCODE = '40001'; END IF;

  v_color := CASE WHEN v_uid = m.player_white THEN 'w' ELSE 'b' END;
  IF (m.state->>'turn') IS DISTINCT FROM v_color THEN
    RAISE EXCEPTION 'not_your_turn' USING ERRCODE = 'P0001';
  END IF;
  IF (p_new_state->>'turn') = v_color AND p_result IS NULL THEN
    RAISE EXCEPTION 'turn_must_pass' USING ERRCODE = '22023';
  END IF;
  IF p_result IS NOT NULL AND p_result NOT IN ('white','black','draw') THEN
    RAISE EXCEPTION 'invalid_result' USING ERRCODE = '22023';
  END IF;

  UPDATE matches SET
    state      = jsonb_set(p_new_state, '{moves}',
                   COALESCE(m.state->'moves','[]'::jsonb) || jsonb_build_array(p_move)),
    version    = version + 1,
    status     = CASE WHEN p_result IS NULL THEN 'active' ELSE 'finished' END,
    winner     = CASE p_result WHEN 'white' THEN m.player_white WHEN 'black' THEN m.player_black END,
    updated_at = now()
  WHERE id = m.id RETURNING * INTO m;
  RETURN m;
END $$;

CREATE OR REPLACE FUNCTION resign_match(p_match_id uuid) RETURNS matches
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := require_uid(); m matches;
BEGIN
  UPDATE matches SET status = 'finished', version = version + 1, updated_at = now(),
         winner = CASE WHEN v_uid = player_white THEN player_black ELSE player_white END
  WHERE id = p_match_id AND status = 'active' AND v_uid IN (player_white, player_black)
  RETURNING * INTO m;
  IF NOT FOUND THEN RAISE EXCEPTION 'match_not_active_or_not_yours' USING ERRCODE = 'P0002'; END IF;
  RETURN m;
END $$;

-- Only ludo_app (and the owner) may call player RPCs.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  app_uid(), require_uid(), online_cutoff(), are_friends(uuid,uuid),
  heartbeat(), get_my_profile(), find_user_by_username(text),
  send_friend_request(text), respond_friend_request(uuid,boolean), remove_friend(uuid), list_friends(),
  create_challenge(uuid,text), accept_challenge(uuid), decline_challenge(uuid),
  cancel_challenge(uuid), list_my_challenges(),
  get_match(uuid), make_move(uuid,integer,jsonb,jsonb,text), resign_match(uuid)
TO ludo_app;

-- ============================================================
-- Realtime for "challenges" and "matches"
-- ============================================================
CREATE OR REPLACE FUNCTION notify_ludo_event() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_users jsonb;
BEGIN
  IF TG_TABLE_NAME = 'challenges' THEN
    v_users := jsonb_build_array(NEW.from_user, NEW.to_user);
  ELSE
    v_users := jsonb_build_array(NEW.player_white, NEW.player_black);
  END IF;
  PERFORM pg_notify('ludo_events', jsonb_build_object(
    'table', TG_TABLE_NAME, 'op', TG_OP, 'id', NEW.id,
    'status', NEW.status, 'users', v_users)::text);
  RETURN NEW;
END $$;

CREATE TRIGGER challenges_realtime AFTER INSERT OR UPDATE ON challenges
  FOR EACH ROW EXECUTE FUNCTION notify_ludo_event();
CREATE TRIGGER matches_realtime AFTER INSERT OR UPDATE ON matches
  FOR EACH ROW EXECUTE FUNCTION notify_ludo_event();
