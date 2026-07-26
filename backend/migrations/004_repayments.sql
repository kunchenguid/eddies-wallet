CREATE TABLE repayments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  loan_id uuid NOT NULL REFERENCES loans(id) ON DELETE RESTRICT,
  ledger_entry_id uuid NOT NULL UNIQUE REFERENCES ledger_entries(id) ON DELETE RESTRICT,
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  recorded_by_identity_id uuid NOT NULL REFERENCES parent_identities(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX repayments_loan_created_idx ON repayments (loan_id, created_at ASC);

CREATE FUNCTION validate_repayment_entry() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  entry ledger_entries%ROWTYPE;
BEGIN
  SELECT * INTO entry FROM ledger_entries WHERE id = NEW.ledger_entry_id;
  IF entry.id IS NULL OR entry.entry_type <> 'repayment' OR entry.loan_id <> NEW.loan_id
     OR entry.amount_cents <> NEW.amount_cents THEN
    RAISE EXCEPTION 'repayment must reference its matching accepted ledger entry' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER repayments_validate_entry
  BEFORE INSERT ON repayments FOR EACH ROW EXECUTE FUNCTION validate_repayment_entry();

CREATE FUNCTION reject_repayment_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'accepted repayments are immutable' USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER repayments_immutable
  BEFORE UPDATE OR DELETE ON repayments
  FOR EACH ROW EXECUTE FUNCTION reject_repayment_mutation();
