CREATE TABLE allowance_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id uuid NOT NULL UNIQUE REFERENCES wallets(id) ON DELETE RESTRICT,
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  cadence text NOT NULL CHECK (cadence = 'weekly'),
  weekday smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  start_date date NOT NULL,
  end_date date,
  active boolean NOT NULL DEFAULT true,
  created_by_identity_id uuid NOT NULL REFERENCES parent_identities(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (end_date IS NULL OR end_date >= start_date)
);

CREATE TABLE allowance_occurrences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rule_id uuid NOT NULL REFERENCES allowance_rules(id) ON DELETE RESTRICT,
  due_on date NOT NULL,
  status text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled', 'recorded', 'cancelled')),
  accepted_entry_id uuid UNIQUE REFERENCES ledger_entries(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (rule_id, due_on),
  CHECK ((status = 'recorded' AND accepted_entry_id IS NOT NULL)
      OR (status IN ('scheduled', 'cancelled') AND accepted_entry_id IS NULL))
);

CREATE INDEX allowance_occurrences_next_idx
  ON allowance_occurrences (rule_id, due_on)
  WHERE status = 'scheduled';

CREATE TABLE idempotency_records (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_identity_id uuid NOT NULL REFERENCES parent_identities(id) ON DELETE RESTRICT,
  idempotency_key text NOT NULL CHECK (char_length(idempotency_key) BETWEEN 1 AND 128),
  request_hash text NOT NULL,
  response_status smallint,
  response_body jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (actor_identity_id, idempotency_key),
  CHECK ((response_status IS NULL AND response_body IS NULL)
      OR (response_status IS NOT NULL AND response_body IS NOT NULL))
);

CREATE TRIGGER loans_set_updated_at
  BEFORE UPDATE ON loans FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER wallets_set_updated_at
  BEFORE UPDATE ON wallets FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER allowance_rules_set_updated_at
  BEFORE UPDATE ON allowance_rules FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER allowance_occurrences_set_updated_at
  BEFORE UPDATE ON allowance_occurrences FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE UNIQUE INDEX one_open_loan_per_wallet_idx
  ON loans (wallet_id) WHERE status = 'open';

CREATE FUNCTION reject_ledger_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'accepted ledger entries are immutable' USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER ledger_entries_immutable
  BEFORE UPDATE OR DELETE ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION reject_ledger_mutation();

CREATE FUNCTION validate_ledger_balance() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  current_balance bigint;
BEGIN
  SELECT balance_cents INTO current_balance FROM wallets WHERE id = NEW.wallet_id FOR UPDATE;
  IF current_balance IS NULL THEN
    RAISE EXCEPTION 'wallet does not exist' USING ERRCODE = '23503';
  END IF;
  IF NEW.balance_before_cents <> current_balance THEN
    RAISE EXCEPTION 'ledger balance is not the current wallet balance' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER ledger_entries_validate_balance
  BEFORE INSERT ON ledger_entries
  FOR EACH ROW EXECUTE FUNCTION validate_ledger_balance();

CREATE FUNCTION reject_direct_balance_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.balance_cents <> OLD.balance_cents
     AND current_setting('eddys_wallet.allow_balance_update', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'wallet balance changes must be accompanied by an accepted ledger entry' USING ERRCODE = '55000';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER wallets_balance_guard
  BEFORE UPDATE ON wallets
  FOR EACH ROW EXECUTE FUNCTION reject_direct_balance_update();
