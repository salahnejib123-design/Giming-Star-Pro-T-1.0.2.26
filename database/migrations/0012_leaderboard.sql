-- 1.0.3.32: global ranking of players by experience points (online matches only).
-- XP = games x 10 + wins x 30 (robot games do not count). Run once in Supabase, then reply "تم".
CREATE OR REPLACE FUNCTION leaderboard()
RETURNS TABLE (user_id uuid, username text, xp integer, games integer, wins integer, is_online boolean, relation text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := require_uid();
BEGIN
  RETURN QUERY
  WITH played AS (
    SELECT m.player_white AS uid, (m.winner = m.player_white) AS won FROM matches m WHERE m.status = 'finished' AND m.robots = 0
    UNION ALL
    SELECT m.player_black AS uid, (m.winner = m.player_black) AS won FROM matches m WHERE m.status = 'finished' AND m.robots = 0
  ),
  stats AS (
    SELECT pl.uid, count(*)::int AS games, (count(*) FILTER (WHERE pl.won))::int AS wins FROM played pl GROUP BY pl.uid
  )
  SELECT p.id, p.username, (s.games * 10 + s.wins * 30)::int, s.games, s.wins,
         (p.last_seen >= online_cutoff()),
         CASE WHEN f.status = 'accepted' THEN 'friend'
              WHEN f.status = 'pending' AND f.user_a = v_uid THEN 'sent'
              WHEN f.status = 'pending' THEN 'incoming'
              ELSE 'none' END
  FROM stats s
  JOIN profiles p ON p.id = s.uid
  LEFT JOIN friendships f ON (f.user_a = v_uid AND f.user_b = p.id) OR (f.user_b = v_uid AND f.user_a = p.id)
  ORDER BY (s.games * 10 + s.wins * 30) DESC, s.wins DESC, p.username
  LIMIT 50;
END $$;

REVOKE EXECUTE ON FUNCTION leaderboard() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION leaderboard() TO ludo_app;
