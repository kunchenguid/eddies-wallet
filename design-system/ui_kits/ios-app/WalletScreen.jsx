function WalletScreen({ role, onRoleTap, activity, loan, onOpenActivity, onOpenLoan, onAction, onLesson }) {
  const { Icon, RoleSwitch, BalanceDisplay, ActivityRow, LoanCard, Card, Button } = window.EddieSWalletDesignSystem_b072eb;
  const isParent = role === 'parent';

  if (!isParent) {
    return (
      <div style={{ height: '100%', overflowY: 'auto', background: 'var(--surface-app)', boxSizing: 'border-box', padding: '8px 16px 28px', display: 'flex', flexDirection: 'column', gap: 18 }}>
        <div style={{ display: 'flex', justifyContent: 'center' }}>
          <RoleSwitch role={role} onChange={onRoleTap} />
        </div>

        <div className="ewa-dots ewa-bounce-in" style={{ position: 'relative', overflow: 'hidden', flexShrink: 0, borderRadius: 'var(--radius-xl)', background: 'var(--brand-primary)', padding: '26px 20px', color: 'var(--green-300)', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10, textAlign: 'center' }}>
          <span style={{ position: 'absolute', top: 14, right: 18, transform: 'rotate(12deg)', background: 'var(--gold-500)', color: 'var(--white)', font: '700 12px var(--font-display)', padding: '5px 10px', borderRadius: 'var(--radius-pill)', boxShadow: 'var(--shadow-sm)' }}>Nice job!</span>
          <div className="ewa-float" style={{ width: 72, height: 72, borderRadius: '50%', background: 'var(--white)', display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: 'var(--shadow-md)' }}>
            <Icon name="piggy-bank" size={38} color="var(--brand-primary)" />
          </div>
          <div style={{ font: '600 16px var(--font-display)', color: 'var(--white)', opacity: .9 }}>Hi, Eddie! 👋</div>
          <div style={{ font: '700 56px var(--font-display)', color: 'var(--white)' }}>US$24.00</div>
          <div style={{ font: 'var(--text-body-sm)', color: 'var(--white)', opacity: .85, maxWidth: 260 }}>Pretend dollars for practice — not real money.</div>
        </div>

        <div className="ewa-kid-tap ewa-bounce-in" onClick={onOpenLoan} style={{ cursor: 'pointer', animationDelay: '.08s', flexShrink: 0 }}>
          <LoanCard remaining="6.00" total={10} dueDate="Aug 15" paid={false} onRepay={(e) => { e && e.stopPropagation && e.stopPropagation(); onOpenLoan(); }} />
        </div>

        <div className="ewa-kid-tap ewa-bounce-in" onClick={onLesson} style={{ cursor: 'pointer', animationDelay: '.14s', flexShrink: 0, borderRadius: 'var(--radius-xl)', background: 'var(--accent-gold-tint)', padding: 18, display: 'flex', alignItems: 'center', gap: 14 }}>
          <div className="ewa-wiggle" style={{ width: 56, height: 56, borderRadius: '50%', background: 'var(--gold-500)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
            <Icon name="book-open" size={26} color="var(--white)" />
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ font: '700 17px var(--font-display)', color: 'var(--text-primary)' }}>Next lesson</div>
            <div style={{ font: 'var(--text-body-sm)', color: 'var(--text-secondary)' }}>Borrow and repay · 3 of 4</div>
          </div>
          <Icon name="chevron-right" size={20} color="var(--gold-700)" />
        </div>

        <div>
          <div style={{ font: '600 18px var(--font-display)', color: 'var(--text-primary)', marginBottom: 8 }}>What's been happening</div>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {activity.map((a, i) => (
              <div key={i} className="ewa-kid-tap ewa-bounce-in" onClick={() => onOpenActivity(a)} style={{ cursor: 'pointer', animationDelay: `${.2 + i * .05}s`, borderRadius: 'var(--radius-lg)', background: 'var(--surface-card)', boxShadow: 'var(--shadow-sm)' }}>
                <ActivityRow {...a} bold onClick={() => onOpenActivity(a)} />
              </div>
            ))}
          </div>
        </div>
      </div>
    );
  }

  return (
    <div style={{ height: '100%', overflowY: 'auto', background: 'var(--surface-app)', boxSizing: 'border-box', padding: '8px 20px 28px', display: 'flex', flexDirection: 'column', gap: 20 }}>
      <div style={{ display: 'flex', justifyContent: 'center' }}>
        <RoleSwitch role={role} onChange={onRoleTap} />
      </div>

      <Card>
        <BalanceDisplay amount="24.00" lastUpdated="2 min ago" />
      </Card>

      <Card variant="alt" style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
        <Icon name="calendar" size={20} color="var(--gold-700)" />
        <div>
          <div style={{ font: 'var(--text-body-md-bold)', color: 'var(--text-primary)' }}>Next allowance</div>
          <div style={{ font: 'var(--text-body-sm)', color: 'var(--text-secondary)' }}>US$10.00 every Friday, starting Aug 1</div>
        </div>
      </Card>

      <div onClick={onOpenLoan} style={{ cursor: 'pointer' }}>
        <LoanCard remaining="6.00" total={10} dueDate="Aug 15" paid={false} onRepay={(e) => { e && e.stopPropagation && e.stopPropagation(); onOpenLoan(); }} />
      </div>

      <div>
        <div style={{ font: 'var(--text-heading-md)', color: 'var(--text-primary)', marginBottom: 4 }}>Recent Activity</div>
        <Card style={{ display: 'flex', flexDirection: 'column' }}>
          {activity.map((a, i) => (
            <div key={i} style={{ borderBottom: i < activity.length - 1 ? '1px solid var(--border-subtle)' : 'none' }}>
              <ActivityRow {...a} onClick={() => onOpenActivity(a)} />
            </div>
          ))}
        </Card>
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        <div style={{ display: 'flex', gap: 10 }}>
          <Button variant="primary" icon={<Icon name="circle-arrow-down" size={18} />} onClick={() => onAction('deposit')} style={{ flex: 1 }}>Deposit</Button>
          <Button variant="secondary" icon={<Icon name="circle-arrow-up" size={18} />} onClick={() => onAction('withdrawal')} style={{ flex: 1 }}>Withdraw</Button>
        </div>
        <Button variant="ghost" icon={<Icon name="hand-coins" size={18} />} onClick={() => onAction('loan')}>Create loan</Button>
      </div>
    </div>
  );
}
window.WalletScreen = WalletScreen;
