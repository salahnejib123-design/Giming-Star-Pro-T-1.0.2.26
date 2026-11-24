DROP FUNCTION IF EXISTS list_friends();
CREATE FUNCTION list_friends()
RETURNS TABLE (user_id uuid, username text, friend_code text, is_online boolean, last_seen timestamptz,
               status text, direction text, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id, p.username, p.friend_code, (p.last_seen >= online_cutoff()), p.last_seen, f.status,
         CASE WHEN f.status = 'accepted' THEN 'friend'
              WHEN f.user_a = require_uid() THEN 'outgoing' ELSE 'incoming' END,
         f.created_at
  FROM friendships f
  JOIN profiles p ON p.id = CASE WHEN f.user_a = require_uid() THEN f.user_b ELSE f.user_a END
  WHERE require_uid() IN (f.user_a, f.user_b)
  ORDER BY f.status, p.username
$$;
REVOKE EXECUTE ON FUNCTION list_friends() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION list_friends() TO ludo_app;
