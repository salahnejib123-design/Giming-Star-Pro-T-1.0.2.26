-- 1.0.3.28: the signed-in player can change the account password.
-- Run once in Supabase (SQL editor), then reply "تم".
CREATE OR REPLACE FUNCTION change_password(p_user_id uuid, p_password_hash text) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE credentials SET password_hash = p_password_hash WHERE user_id = p_user_id
$$;

REVOKE EXECUTE ON FUNCTION change_password(uuid, text) FROM PUBLIC, ludo_app;
