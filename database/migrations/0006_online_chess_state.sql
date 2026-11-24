-- ============================================================
-- Online chess on the normal chess screen (game_type 'chess').
-- The browser computes every move with the chess engine and the
-- server stores the state. The server checks only participation,
-- the turn owner (or an expired 20-second turn) and the version.
-- ============================================================

CREATE OR REPLACE FUNCTION save_chess_state(p_match_id uuid, p_expected_version integer,
                                            p_state jsonb, p_result text DEFAULT NULL)
RETURNS matches
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid   uuid := require_uid();
  m       matches;
  v_turn  text;
  v_owner uuid;
BEGIN
  SELECT * INTO m FROM matches WHERE id = p_match_id FOR UPDATE;
  IF NOT FOUND OR v_uid NOT IN (m.player_white, m.player_black) THEN
    RAISE EXCEPTION 'match_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF m.game_type <> 'chess' THEN RAISE EXCEPTION 'invalid_game_type' USING ERRCODE = '22023'; END IF;
  IF m.status <> 'active' THEN RAISE EXCEPTION 'match_finished' USING ERRCODE = 'P0001'; END IF;
  IF p_expected_version IS NULL OR m.version <> p_expected_version THEN RAISE EXCEPTION 'stale_state' USING ERRCODE = '40001'; END IF;

  -- Shape check only: the chess rules are not validated here.
  IF jsonb_typeof(p_state) IS DISTINCT FROM 'object'
     OR COALESCE(p_state->>'turn', '') NOT IN ('w', 'b')
     OR jsonb_typeof(p_state->'b') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'invalid_state' USING ERRCODE = '22023';
  END IF;
  IF p_result IS NOT NULL AND p_result NOT IN ('white', 'black', 'draw') THEN
    RAISE EXCEPTION 'invalid_result' USING ERRCODE = '22023';
  END IF;

  -- Whose turn the stored state says it is (absent state = white).
  v_turn  := COALESCE(m.state->>'turn', 'w');
  v_owner := CASE v_turn WHEN 'w' THEN m.player_white ELSE m.player_black END;
  IF v_owner IS DISTINCT FROM v_uid AND now() < m.updated_at + interval '20 seconds' THEN
    RAISE EXCEPTION 'not_your_turn' USING ERRCODE = 'P0001';
  END IF;
  -- A move passes the turn (a finished match may keep the same turn).
  IF p_result IS NULL AND (p_state->>'turn') = v_turn THEN
    RAISE EXCEPTION 'turn_must_pass' USING ERRCODE = '22023';
  END IF;

  UPDATE matches SET
    state      = p_state,
    version    = version + 1,
    status     = CASE WHEN p_result IS NULL THEN 'active' ELSE 'finished' END,
    winner     = CASE p_result WHEN 'white' THEN m.player_white WHEN 'black' THEN m.player_black END,
    updated_at = now()
  WHERE id = m.id RETURNING * INTO m;
  RETURN m;
END $$;

REVOKE EXECUTE ON FUNCTION save_chess_state(uuid, integer, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_chess_state(uuid, integer, jsonb, text) TO ludo_app;
