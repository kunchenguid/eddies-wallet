CREATE TABLE wallets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  child_id uuid NOT NULL UNIQUE REFERENCES children(id) ON DELETE RESTRICT,
  currency_code char(3) NOT NULL DEFAULT 'USD' CHECK (currency_code = 'USD'),
  balance_cents bigint NOT NULL DEFAULT 0 CHECK (balance_cents >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE loans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id uuid NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
  principal_cents bigint NOT NULL CHECK (principal_cents > 0),
  outstanding_cents bigint NOT NULL CHECK (outstanding_cents >= 0 AND outstanding_cents <= principal_cents),
  purpose text CHECK (purpose IS NULL OR char_length(purpose) <= 240),
  due_date date,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'paid')),
  created_by_identity_id uuid NOT NULL REFERENCES parent_identities(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  paid_at timestamptz,
  CHECK ((status = 'open' AND outstanding_cents > 0 AND paid_at IS NULL)
      OR (status = 'paid' AND outstanding_cents = 0 AND paid_at IS NOT NULL))
);

CREATE TABLE ledger_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id uuid NOT NULL REFERENCES wallets(id) ON DELETE RESTRICT,
  entry_type text NOT NULL CHECK (entry_type IN ('deposit', 'withdrawal', 'allowance', 'loan', 'repayment')),
  direction text NOT NULL CHECK (direction IN ('credit', 'debit')),
  amount_cents bigint NOT NULL CHECK (amount_cents > 0),
  balance_before_cents bigint NOT NULL CHECK (balance_before_cents >= 0),
  balance_after_cents bigint NOT NULL CHECK (balance_after_cents >= 0),
  reason text CHECK (reason IS NULL OR char_length(reason) <= 240),
  loan_id uuid REFERENCES loans(id) ON DELETE RESTRICT,
  recorded_by_identity_id uuid NOT NULL REFERENCES parent_identities(id) ON DELETE RESTRICT,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((direction = 'credit' AND balance_after_cents = balance_before_cents + amount_cents)
      OR (direction = 'debit' AND balance_after_cents = balance_before_cents - amount_cents)),
  CHECK ((entry_type IN ('deposit', 'allowance', 'loan') AND direction = 'credit')
      OR (entry_type IN ('withdrawal', 'repayment') AND direction = 'debit')),
  CHECK ((entry_type IN ('loan', 'repayment') AND loan_id IS NOT NULL)
      OR (entry_type IN ('deposit', 'withdrawal', 'allowance') AND loan_id IS NULL))
);

CREATE INDEX ledger_entries_wallet_recorded_idx
  ON ledger_entries (wallet_id, recorded_at DESC, id DESC);
CREATE INDEX loans_wallet_created_idx
  ON loans (wallet_id, created_at DESC);
