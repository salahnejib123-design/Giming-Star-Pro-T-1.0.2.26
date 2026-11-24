CREATE OR REPLACE FUNCTION list_my_matches()
RETURNS SETOF matches
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM matches
  WHERE status = 'active' AND require_uid() IN (player_white, player_black)
  ORDER BY updated_at DESC
$$;
CREATE OR REPLACE FUNCTION apply_robot_move(p_match_id uuid, p_expected_version integer, p_move jsonb,
                                            p_new_state jsonb, p_result text DEFAULT NULL)
RETURNS matches
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := require_uid(); m matches;
BEGIN
  SELECT * INTO m FROM matches WHERE id = p_match_id FOR UPDATE;
  IF NOT FOUND OR v_uid NOT IN (m.player_white, m.player_black) THEN
    RAISE EXCEPTION 'match_not_found' USING ERRCODE = 'P0002';
  END IF;
  IF m.status <> 'active' THEN RAISE EXCEPTION 'match_finished' USING ERRCODE = 'P0001'; END IF;
  IF m.version <> p_expected_version THEN RAISE EXCEPTION 'stale_state' USING ERRCODE = '40001'; END IF;
  IF now() < m.updated_at + interval '20 seconds' THEN RAISE EXCEPTION 'turn_not_expired' USING ERRCODE = 'P0001'; END IF;
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
REVOKE EXECUTE ON FUNCTION list_my_matches(), apply_robot_move(uuid,integer,jsonb,jsonb,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION list_my_matches(), apply_robot_move(uuid,integer,jsonb,jsonb,text) TO ludo_app;
