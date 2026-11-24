-- 0009 (1.0.3.13): online Ludo with robots (0, 1 or 2 robots), and leaving a match with robots.
-- Run this whole file once in the Supabase SQL editor, BEFORE the 1.0.3.13 update is used.

-- 1. robots are stored on the challenge and on the match
ALTER TABLE challenges ADD COLUMN IF NOT EXISTS robots smallint NOT NULL DEFAULT 0;
ALTER TABLE challenges DROP CONSTRAINT IF EXISTS challenges_robots_range;
ALTER TABLE challenges ADD CONSTRAINT challenges_robots_range CHECK (robots BETWEEN 0 AND 2);

ALTER TABLE matches ADD COLUMN IF NOT EXISTS robots smallint NOT NULL DEFAULT 0;
ALTER TABLE matches DROP CONSTRAINT IF EXISTS matches_robots_range;
ALTER TABLE matches ADD CONSTRAINT matches_robots_range CHECK (robots BETWEEN 0 AND 2);
-- the player who left a match with robots (their seat becomes a robot)
ALTER TABLE matches ADD COLUMN IF NOT EXISTS left_by uuid;

-- 2. challenge with robots (only for Ludo)
DROP FUNCTION IF EXISTS create_challenge(uuid, text);
CREATE OR REPLACE FUNCTION create_challenge(p_to_user uuid, p_game_type text, p_robots integer DEFAULT 0) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := require_uid(); v_id uuid; v_now timestamptz := now(); v_robots integer := COALESCE(p_robots, 0);
BEGIN
  PERFORM expire_stale_challenges();
  IF p_game_type NOT IN ('robot_ai','friends','chess') THEN
    RAISE EXCEPTION 'invalid_game_type' USING ERRCODE = '22023';
  END IF;
  IF v_robots NOT BETWEEN 0 AND 2 OR (v_robots > 0 AND p_game_type <> 'friends') THEN
    RAISE EXCEPTION 'invalid_robots' USING ERRCODE = '22023';
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

  INSERT INTO challenges (from_user, to_user, game_type, created_at, expires_at, robots)
  VALUES (v_uid, p_to_user, p_game_type, v_now, v_now + interval '30 seconds', v_robots)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- 3. accepting copies the robots into the match
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
  INSERT INTO matches (challenge_id, player_white, player_black, game_type, state, robots)
  VALUES (c.id, c.from_user, c.to_user, c.game_type, v_state, c.robots)
  RETURNING id INTO v_match;
  RETURN v_match;
END $$;

-- 4. surrender: with robots the match goes on (the leaver's seat becomes a robot); without robots it ends
CREATE OR REPLACE FUNCTION resign_match(p_match_id uuid) RETURNS matches
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := require_uid(); m matches;
BEGIN
  SELECT * INTO m FROM matches
  WHERE id = p_match_id AND status = 'active' AND v_uid IN (player_white, player_black)
    AND (left_by IS NULL OR left_by <> v_uid)
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'match_not_active_or_not_yours' USING ERRCODE = 'P0002'; END IF;

  IF m.robots > 0 AND m.game_type = 'friends' AND m.left_by IS NULL THEN
    UPDATE matches SET left_by = v_uid, version = version + 1, updated_at = now()
    WHERE id = m.id RETURNING * INTO m;
  ELSE
    UPDATE matches SET status = 'finished', version = version + 1, updated_at = now(),
           winner = CASE WHEN m.left_by IS NOT NULL THEN NULL
                         WHEN v_uid = player_white THEN player_black ELSE player_white END
    WHERE id = m.id RETURNING * INTO m;
  END IF;
  RETURN m;
END $$;

-- 5. a player who left does not see the match any more
CREATE OR REPLACE FUNCTION list_my_matches()
RETURNS SETOF matches
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM matches
  WHERE status = 'active' AND require_uid() IN (player_white, player_black)
    AND (left_by IS NULL OR left_by <> require_uid())
  ORDER BY updated_at DESC
$$;

-- 6. Ludo saves: the turn owner of a robot seat is the player who stayed (the host);
--    a seat of a player who left is a robot; a robot may win (result 'bot', no winner player)
CREATE OR REPLACE FUNCTION save_ludo_state(p_match_id uuid, p_expected_version integer,
                                           p_state jsonb, p_result text DEFAULT NULL)
RETURNS matches
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid   uuid := require_uid();
  m       matches;
  v_turn  integer;
  v_host  uuid;
  v_owner uuid;
  v_reset boolean;
BEGIN
  SELECT * INTO m FROM matches WHERE id = p_match_id FOR UPDATE;
  IF NOT FOUND OR v_uid NOT IN (m.player_white, m.player_black) THEN
    RAISE EXCEPTION 'match_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF m.game_type <> 'friends' THEN RAISE EXCEPTION 'invalid_game_type' USING ERRCODE = '22023'; END IF;
  IF m.status <> 'active' OR m.left_by = v_uid THEN RAISE EXCEPTION 'match_finished' USING ERRCODE = 'P0001'; END IF;
  IF p_expected_version IS NULL OR m.version <> p_expected_version THEN RAISE EXCEPTION 'stale_state' USING ERRCODE = '40001'; END IF;

  -- Shape check only: the Ludo rules are not validated here.
  IF jsonb_typeof(p_state) IS DISTINCT FROM 'object'
     OR NOT (COALESCE(p_state->>'turn', '') ~ '^[0-3]$')
     OR NOT (COALESCE(p_state->>'turnNo', '') ~ '^[0-9]{1,9}$')
     OR COALESCE(p_state->>'phase', '') NOT IN ('roll', 'move', 'bonus', 'over') THEN
    RAISE EXCEPTION 'invalid_state' USING ERRCODE = '22023';
  END IF;
  IF p_result IS NOT NULL AND p_result NOT IN ('white', 'black', 'bot') THEN
    RAISE EXCEPTION 'invalid_result' USING ERRCODE = '22023';
  END IF;
  IF (p_state->>'phase' = 'over') IS DISTINCT FROM (p_result IS NOT NULL) THEN
    RAISE EXCEPTION 'invalid_state' USING ERRCODE = '22023';
  END IF;

  -- Whose turn the stored state says it is (absent state = seat 0, the challenger).
  v_turn := COALESCE((m.state->'ludo'->>'turn')::integer, 0);
  -- the player who stayed hosts the robots (for a match without a leaver, the challenger)
  v_host := CASE WHEN m.left_by IS NOT DISTINCT FROM m.player_white THEN m.player_black ELSE m.player_white END;
  v_owner := CASE v_turn
    WHEN 0 THEN CASE WHEN m.left_by IS NOT DISTINCT FROM m.player_white THEN v_host ELSE m.player_white END
    WHEN 2 THEN CASE WHEN m.left_by IS NOT DISTINCT FROM m.player_black THEN v_host ELSE m.player_black END
    ELSE v_host END;
  IF v_owner IS DISTINCT FROM v_uid AND now() < m.updated_at + interval '20 seconds' THEN
    RAISE EXCEPTION 'not_your_turn' USING ERRCODE = 'P0001';
  END IF;

  -- The timer restarts when the turn passes to another seat or to a new turn (a six gives a new turn for the same seat).
  v_reset := (p_state->>'turn') IS DISTINCT FROM v_turn::text
          OR (p_state->>'turnNo') IS DISTINCT FROM (m.state->'ludo'->>'turnNo');

  UPDATE matches SET
    state      = jsonb_set(m.state, '{ludo}', p_state, true),
    version    = version + 1,
    status     = CASE WHEN p_result IS NULL THEN 'active' ELSE 'finished' END,
    winner     = CASE p_result WHEN 'white' THEN m.player_white WHEN 'black' THEN m.player_black ELSE NULL END,
    updated_at = CASE WHEN v_reset THEN now() ELSE m.updated_at END
  WHERE id = m.id RETURNING * INTO m;
  RETURN m;
END $$;

-- 7. grants for the new / changed functions (only the app role may call them)
REVOKE EXECUTE ON FUNCTION create_challenge(uuid, text, integer), accept_challenge(uuid), resign_match(uuid),
  list_my_matches(), save_ludo_state(uuid, integer, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_challenge(uuid, text, integer), accept_challenge(uuid), resign_match(uuid),
  list_my_matches(), save_ludo_state(uuid, integer, jsonb, text) TO ludo_app;
