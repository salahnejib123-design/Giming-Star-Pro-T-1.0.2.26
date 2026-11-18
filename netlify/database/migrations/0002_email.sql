ALTER TABLE profiles ADD COLUMN IF NOT EXISTS email text;
CREATE OR REPLACE FUNCTION set_my_email(p_email text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid uuid := require_uid();
BEGIN
  IF p_email IS NOT NULL AND p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'invalid_email' USING ERRCODE = '22023';
  END IF;
  UPDATE profiles SET email = p_email WHERE id = v_uid;
END $$;
REVOKE EXECUTE ON FUNCTION set_my_email(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION set_my_email(text) TO ludo_app;
