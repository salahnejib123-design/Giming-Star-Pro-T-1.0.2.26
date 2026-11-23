-- 0008: online nickname = at least 4 characters, any characters (1.0.2.95).
-- Run once in the database SQL editor. Safe to run on the existing data.

ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_username_check;
ALTER TABLE profiles ADD CONSTRAINT profiles_username_check
  CHECK (char_length(username) BETWEEN 3 AND 40);   -- 3 keeps old accounts valid

CREATE OR REPLACE FUNCTION sign_up(p_username text, p_friend_code text, p_password_hash text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_code text := upper(trim(p_friend_code));
BEGIN
  IF char_length(trim(p_username)) < 4 OR char_length(trim(p_username)) > 40 THEN
    RAISE EXCEPTION 'invalid_username: 4 to 40 characters' USING ERRCODE = '22023';
  END IF;
  IF v_code !~ '^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$' THEN
    RAISE EXCEPTION 'invalid_friend_code: format XXXX-XXXX, no 0/O/1/I' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM profiles WHERE lower(username) = lower(p_username)) THEN
    RAISE EXCEPTION 'username_taken' USING ERRCODE = '23505';
  END IF;
  IF EXISTS (SELECT 1 FROM profiles WHERE friend_code = v_code) THEN
    RAISE EXCEPTION 'friend_code_taken' USING ERRCODE = '23505';
  END IF;
  INSERT INTO profiles (username, friend_code) VALUES (p_username, v_code) RETURNING id INTO v_id;
  INSERT INTO credentials (user_id, password_hash) VALUES (v_id, p_password_hash);
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN  -- race between the checks and the insert
  IF SQLERRM LIKE '%username%' THEN RAISE EXCEPTION 'username_taken' USING ERRCODE = '23505';
  ELSE RAISE EXCEPTION 'friend_code_taken' USING ERRCODE = '23505'; END IF;
END $$;
