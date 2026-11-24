-- 0010 (1.0.3.14): robot strength for online Ludo (easy, normal, hard).
-- Run this whole file once in the Supabase SQL editor, after 0009 and before the next update is used.

-- 1. the strength is stored on the challenge and copied to the match
ALTER TABLE challenges ADD COLUMN IF NOT EXISTS diff text NOT NULL DEFAULT 'normal';
ALTER TABLE challenges DROP CONSTRAINT IF EXISTS challenges_diff_values;
ALTER TABLE challenges ADD CONSTRAINT challenges_diff_values CHECK (diff IN ('easy', 'normal', 'hard'));

ALTER TABLE matches ADD COLUMN IF NOT EXISTS diff text NOT NULL DEFAULT 'normal';
ALTER TABLE matches DROP CONSTRAINT IF EXISTS matches_diff_values;
ALTER TABLE matches ADD CONSTRAINT matches_diff_values CHECK (diff IN ('easy', 'normal', 'hard'));

-- 2. challenge with robots and their strength (only for Ludo)
DROP FUNCTION IF EXISTS create_challenge(uuid, text, integer);
CREATE OR REPLACE FUNCTION create_challenge(p_to_user uuid, p_game_type text, p_robots integer DEFAULT 0,
                                            p_diff text DEFAULT 'normal') RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := require_uid(); v_id uuid; v_now timestamptz := now();
        v_robots integer := COALESCE(p_robots, 0); v_diff text := COALESCE(p_diff, 'normal');
BEGIN
  PERFORM expire_stale_challenges();
  IF p_game_type NOT IN ('robot_ai','friends','chess') THEN
    RAISE EXCEPTION 'invalid_game_type' USING ERRCODE = '22023';
  END IF;
  IF v_robots NOT BETWEEN 0 AND 2 OR (v_robots > 0 AND p_game_type <> 'friends') THEN
    RAISE EXCEPTION 'invalid_robots' USING ERRCODE = '22023';
  END IF;
  IF v_diff NOT IN ('easy', 'normal', 'hard') THEN
    RAISE EXCEPTION 'invalid_diff' USING ERRCODE = '22023';
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

  INSERT INTO challenges (from_user, to_user, game_type, created_at, expires_at, robots, diff)
  VALUES (v_uid, p_to_user, p_game_type, v_now, v_now + interval '30 seconds', v_robots, v_diff)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- 3. accepting copies the robots and their strength into the match
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
  INSERT INTO matches (challenge_id, player_white, player_black, game_type, state, robots, diff)
  VALUES (c.id, c.from_user, c.to_user, c.game_type, v_state, c.robots, c.diff)
  RETURNING id INTO v_match;
  RETURN v_match;
END $$;

-- 4. grants
REVOKE EXECUTE ON FUNCTION create_challenge(uuid, text, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_challenge(uuid, text, integer, text) TO ludo_app;
