function PinSheet({ onSuccess, onClose }) {
  const { PinPad, Icon } = window.EddieSWalletDesignSystem_b072eb;
  const [pin, setPin] = React.useState('');
  const [error, setError] = React.useState(false);
  React.useEffect(() => {
    if (pin.length === 4) {
      if (pin === '1234') { onSuccess(); }
      else { setError(true); setTimeout(() => setPin(''), 400); }
    } else if (error) setError(false);
  }, [pin]);
  return (
    <div className="ewa-sheet-overlay">
      <div className="ewa-sheet" style={{ textAlign: 'center', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 20 }}>
        <div className="ewa-sheet-handle" />
        <Icon name="lock" size={28} color="var(--brand-primary)" />
        <div style={{ font: 'var(--text-heading-lg)', color: 'var(--text-primary)' }}>Enter parent PIN</div>
        <div style={{ font: 'var(--text-body-sm)', color: error ? 'var(--state-danger)' : 'var(--text-tertiary)' }}>
          {error ? 'Incorrect PIN — try again' : 'Protects parent mode on this iPad. Try 1234.'}
        </div>
        <PinPad value={pin} onChange={setPin} />
        <button onClick={onClose} style={{ background: 'none', border: 'none', font: 'var(--text-body-sm)', color: 'var(--text-tertiary)', marginTop: 8 }}>Cancel</button>
      </div>
    </div>
  );
}

function ActivityDetailSheet({ item, onClose }) {
  const { Icon, StatusPill } = window.EddieSWalletDesignSystem_b072eb;
  if (!item) return null;
  return (
    <div className="ewa-sheet-overlay" onClick={onClose}>
      <div className="ewa-sheet" onClick={(e) => e.stopPropagation()}>
        <div className="ewa-sheet-handle" />
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <div>
            <div style={{ font: 'var(--text-heading-lg)', color: 'var(--text-primary)' }}>{item.title}</div>
            <div style={{ font: 'var(--text-body-sm)', color: 'var(--text-tertiary)' }}>{item.subtitle}</div>
          </div>
          <StatusPill status="recorded" />
        </div>
        <div style={{ marginTop: 20, font: 'var(--text-display-md)', color: item.positive === false ? 'var(--text-primary)' : 'var(--green-700)' }}>
          {item.positive === false ? '-' : '+'}US${item.amount}
        </div>
        <div style={{ marginTop: 16, font: 'var(--text-body-md)', color: 'var(--text-secondary)' }}>{item.explain}</div>
      </div>
    </div>
  );
}

function LoanDetailSheet({ isParent, onClose, onRepay }) {
  const { Icon, LoanCard, Button } = window.EddieSWalletDesignSystem_b072eb;
  return (
    <div className="ewa-sheet-overlay" onClick={onClose}>
      <div className="ewa-sheet" onClick={(e) => e.stopPropagation()}>
        <div className="ewa-sheet-handle" />
        <div style={{ font: 'var(--text-heading-lg)', color: 'var(--text-primary)', marginBottom: 16 }}>Loan details</div>
        <LoanCard remaining="6.00" total={10} dueDate="Aug 15" onRepay={isParent ? onRepay : undefined} />
        <div style={{ marginTop: 16, font: 'var(--text-body-sm)', color: 'var(--text-secondary)' }}>
          {isParent ? 'Original loan: US$10.00 for a bike helmet, created Jul 18.' : 'Your parent gave you US$10.00 to use now. You give it back a little at a time — that\u2019s a repayment.'}
        </div>
      </div>
    </div>
  );
}

function MoneyFlowSheet({ kind, onClose, onConfirm }) {
  const { Icon, Input, Button } = window.EddieSWalletDesignSystem_b072eb;
  const [step, setStep] = React.useState('amount');
  const [amount, setAmount] = React.useState('');
  const titles = { deposit: 'Add deposit', withdrawal: 'Record withdrawal', loan: 'Create loan', repay: 'Record repayment' };
  return (
    <div className="ewa-sheet-overlay" onClick={onClose}>
      <div className="ewa-sheet" onClick={(e) => e.stopPropagation()}>
        <div className="ewa-sheet-handle" />
        <div style={{ font: 'var(--text-heading-lg)', color: 'var(--text-primary)', marginBottom: 16 }}>{titles[kind] || 'Record'}</div>
        {step === 'amount' ? (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
            <Input label="Amount" prefix="US$" placeholder="0.00" value={amount} onChange={(e) => setAmount(e.target.value)} />
            <Button variant="primary" disabled={!amount} onClick={() => setStep('review')}>Continue</Button>
          </div>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
            <div style={{ font: 'var(--text-body-md)', color: 'var(--text-primary)' }}>
              US${amount || '0.00'} will be {kind === 'withdrawal' ? 'recorded as used from' : kind === 'repay' ? 'repaid toward' : 'added to'} Eddie's wallet.
            </div>
            <div style={{ font: 'var(--text-body-sm)', color: 'var(--text-tertiary)' }}>Virtual practice only — never real money.</div>
            <Button variant="primary" onClick={() => onConfirm(amount || '0.00')}>Confirm</Button>
            <Button variant="ghost" size="sm" onClick={() => setStep('amount')}>Back</Button>
          </div>
        )}
      </div>
    </div>
  );
}

window.PinSheet = PinSheet;
window.ActivityDetailSheet = ActivityDetailSheet;
window.LoanDetailSheet = LoanDetailSheet;
window.MoneyFlowSheet = MoneyFlowSheet;
