-- 1.0.3.33: the ranking can be searched by name; each player keeps his real rank (1, 2, 3 ...).
-- Run once in Supabase (SQL editor), then reply "تم".
DROP FUNCTION IF EXISTS leaderboard();

CREATE OR REPLACE FUNCTION leaderboard(p_query text DEFAULT '')
RETURNS TABLE (rank integer, user_id uuid, username text, xp integer, games integer, wins integer, is_online boolean, relation text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := require_uid();
  v_q text := btrim(coalesce(p_query, ''));
  v_like text := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
BEGIN
  RETURN QUERY
  WITH played AS (
    SELECT m.player_white AS uid, (m.winner = m.player_white) AS won FROM matches m WHERE m.status = 'finished' AND m.robots = 0
    UNION ALL
    SELECT m.player_black AS uid, (m.winner = m.player_black) AS won FROM matches m WHERE m.status = 'finished' AND m.robots = 0
  ),
  stats AS (
    SELECT pl.uid, count(*)::int AS games, (count(*) FILTER (WHERE pl.won))::int AS wins FROM played pl GROUP BY pl.uid
  ),
  ranked AS (
    SELECT p.id AS uid, p.username AS uname, (s.games * 10 + s.wins * 30)::int AS xp, s.games, s.wins,
           (p.last_seen >= online_cutoff()) AS online,
           row_number() OVER (ORDER BY (s.games * 10 + s.wins * 30) DESC, s.wins DESC, p.username)::int AS rk
    FROM stats s JOIN profiles p ON p.id = s.uid
  )
  SELECT r.rk, r.uid, r.uname, r.xp, r.games, r.wins, r.online,
         CASE WHEN f.status = 'accepted' THEN 'friend'
              WHEN f.status = 'pending' AND f.user_a = v_uid THEN 'sent'
              WHEN f.status = 'pending' THEN 'incoming'
              ELSE 'none' END
  FROM ranked r
  LEFT JOIN friendships f ON (f.user_a = v_uid AND f.user_b = r.uid) OR (f.user_b = v_uid AND f.user_a = r.uid)
  WHERE v_q = '' OR r.uname ILIKE v_like
  ORDER BY CASE WHEN v_q = '' THEN 0 WHEN lower(r.uname) = lower(v_q) THEN 0 WHEN r.uname ILIKE v_q || '%' THEN 1 ELSE 2 END, r.rk
  LIMIT 50;
END $$;

REVOKE EXECUTE ON FUNCTION leaderboard(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION leaderboard(text) TO ludo_app;
