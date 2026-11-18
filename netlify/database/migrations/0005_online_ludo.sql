-- ============================================================
-- Online Ludo (game_type 'friends'): the server stores the match state
-- and checks only participation, turn ownership or an expired turn, and
-- the version. The browser computes every move with the Ludo engine.
--
-- Seats: the challenger (player_white) is seat 0, the other player
-- (player_black) is seat 2. The timer runs from matches.updated_at and is
-- reset only when the turn index or the turn counter changes.
-- ============================================================

CREATE OR REPLACE FUNCTION save_ludo_state(p_match_id uuid, p_expected_version integer,
                                           p_state jsonb, p_result text DEFAULT NULL)
RETURNS matches
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid   uuid := require_uid();
  m       matches;
  v_turn  integer;
  v_owner uuid;
  v_reset boolean;
BEGIN
  SELECT * INTO m FROM matches WHERE id = p_match_id FOR UPDATE;
  IF NOT FOUND OR v_uid NOT IN (m.player_white, m.player_black) THEN
    RAISE EXCEPTION 'match_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF m.game_type <> 'friends' THEN RAISE EXCEPTION 'invalid_game_type' USING ERRCODE = '22023'; END IF;
  IF m.status <> 'active' THEN RAISE EXCEPTION 'match_finished' USING ERRCODE = 'P0001'; END IF;
  IF p_expected_version IS NULL OR m.version <> p_expected_version THEN RAISE EXCEPTION 'stale_state' USING ERRCODE = '40001'; END IF;

  -- Shape check only: the Ludo rules are not validated here.
  IF jsonb_typeof(p_state) IS DISTINCT FROM 'object'
     OR NOT (COALESCE(p_state->>'turn', '') ~ '^[02]$')
     OR NOT (COALESCE(p_state->>'turnNo', '') ~ '^[0-9]{1,9}$')
     OR COALESCE(p_state->>'phase', '') NOT IN ('roll', 'move', 'bonus', 'over') THEN
    RAISE EXCEPTION 'invalid_state' USING ERRCODE = '22023';
  END IF;
  IF p_result IS NOT NULL AND p_result NOT IN ('white', 'black') THEN
    RAISE EXCEPTION 'invalid_result' USING ERRCODE = '22023';
  END IF;
  IF (p_state->>'phase' = 'over') IS DISTINCT FROM (p_result IS NOT NULL) THEN
    RAISE EXCEPTION 'invalid_state' USING ERRCODE = '22023';
  END IF;

  -- Whose turn the stored state says it is (absent state = seat 0, the challenger).
  v_turn  := COALESCE((m.state->'ludo'->>'turn')::integer, 0);
  v_owner := CASE v_turn WHEN 0 THEN m.player_white WHEN 2 THEN m.player_black END;
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
    winner     = CASE p_result WHEN 'white' THEN m.player_white WHEN 'black' THEN m.player_black END,
    updated_at = CASE WHEN v_reset THEN now() ELSE m.updated_at END
  WHERE id = m.id RETURNING * INTO m;
  RETURN m;
END $$;

REVOKE EXECUTE ON FUNCTION save_ludo_state(uuid, integer, jsonb, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION save_ludo_state(uuid, integer, jsonb, text) TO ludo_app;
