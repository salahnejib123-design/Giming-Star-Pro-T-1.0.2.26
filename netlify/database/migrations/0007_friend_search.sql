-- ============================================================
-- Friend search (partial names, live) and adding a player you found.
-- ============================================================

CREATE OR REPLACE FUNCTION search_users(p_query text)
RETURNS TABLE (id uuid, username text, is_online boolean, relation text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := require_uid();
  v_q   text := trim(p_query);
  v_pat text;
BEGIN
  IF length(v_q) < 2 THEN RETURN; END IF;
  v_pat := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  RETURN QUERY
  SELECT p.id, p.username, (p.last_seen >= online_cutoff()),
         CASE WHEN f.status = 'accepted' THEN 'friend'
              WHEN f.status = 'pending' AND f.user_a = v_uid THEN 'sent'
              WHEN f.status = 'pending' THEN 'incoming'
              ELSE 'none' END
  FROM profiles p
  LEFT JOIN friendships f
    ON (f.user_a = v_uid AND f.user_b = p.id) OR (f.user_b = v_uid AND f.user_a = p.id)
  WHERE p.id <> v_uid AND p.username ILIKE v_pat
  ORDER BY (lower(p.username) = lower(v_q)) DESC, p.username
  LIMIT 8;
END $$;

CREATE OR REPLACE FUNCTION add_friend_by_id(p_user uuid) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_code text;
BEGIN
  SELECT friend_code INTO v_code FROM profiles WHERE id = p_user;
  IF v_code IS NULL THEN RAISE EXCEPTION 'friend_code_not_found' USING ERRCODE = 'P0002'; END IF;
  RETURN send_friend_request(v_code);
END $$;

REVOKE EXECUTE ON FUNCTION search_users(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION add_friend_by_id(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION search_users(text) TO ludo_app;
GRANT EXECUTE ON FUNCTION add_friend_by_id(uuid) TO ludo_app;
