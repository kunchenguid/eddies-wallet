CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE parent_identities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL CHECK (provider IN ('apple', 'local')),
  subject text NOT NULL,
  email text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider, subject)
);

CREATE TABLE sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_identity_id uuid NOT NULL REFERENCES parent_identities(id) ON DELETE RESTRICT,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  CHECK (expires_at > created_at)
);

CREATE INDEX sessions_active_lookup_idx
  ON sessions (token_hash, expires_at)
  WHERE revoked_at IS NULL;

CREATE TABLE families (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_identity_id uuid NOT NULL UNIQUE REFERENCES parent_identities(id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 120),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE children (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  family_id uuid NOT NULL UNIQUE REFERENCES families(id) ON DELETE RESTRICT,
  nickname text NOT NULL CHECK (char_length(nickname) BETWEEN 1 AND 80),
  avatar_url text CHECK (avatar_url IS NULL OR char_length(avatar_url) <= 2048),
  lesson_age_band text NOT NULL CHECK (char_length(lesson_age_band) BETWEEN 1 AND 32),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER parent_identities_set_updated_at
  BEFORE UPDATE ON parent_identities FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER families_set_updated_at
  BEFORE UPDATE ON families FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER children_set_updated_at
  BEFORE UPDATE ON children FOR EACH ROW EXECUTE FUNCTION set_updated_at();
