function LessonScreen({ onBack }) {
  const { Icon, Button } = window.EddieSWalletDesignSystem_b072eb;
  return (
    <div style={{ height: '100%', background: 'var(--surface-app)', boxSizing: 'border-box', padding: '8px 20px 28px', display: 'flex', flexDirection: 'column', gap: 18 }}>
      <button onClick={onBack} style={{ alignSelf: 'flex-start', background: 'none', border: 'none', display: 'flex', alignItems: 'center', gap: 4, color: 'var(--text-secondary)', font: 'var(--text-body-md)' }}>
        <Icon name="chevron-left" size={18} /> Wallet
      </button>
      <div className="ewa-dots ewa-bounce-in" style={{ borderRadius: 'var(--radius-xl)', background: 'var(--accent-peach)', padding: '26px 20px', color: 'var(--peach-300)', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 12, textAlign: 'center', overflow: 'hidden', flexShrink: 0 }}>
        <div className="ewa-float" style={{ width: 80, height: 80, borderRadius: '50%', background: 'var(--white)', display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: 'var(--shadow-md)' }}>
          <Icon name="hand-coins" size={40} color="var(--accent-peach-strong)" />
        </div>
        <div style={{ font: '700 27px var(--font-display)', color: 'var(--white)' }}>Borrow and repay</div>
      </div>
      <div style={{ font: 'var(--text-body-lg)', color: 'var(--text-primary)' }}>
        A loan means your parent gives you virtual dollars to use now. You don't have to pay it all back at once — every repayment lowers what's left, a little at a time.
      </div>
      <div style={{ font: 'var(--text-body-md)', color: 'var(--text-secondary)' }}>
        Right now you have US$6.00 left to repay from a US$10.00 loan.
      </div>
      <div style={{ flex: 1 }} />
      <div style={{ display: 'flex', gap: 10, justifyContent: 'center' }}>
        {[0, 1, 2, 3].map((i) => (
          <div key={i} className="ewa-bead" style={{ width: i === 2 ? 20 : 14, height: i === 2 ? 20 : 14, borderRadius: '50%', background: i <= 2 ? 'var(--accent-peach-strong)' : 'var(--ink-100)' }} />
        ))}
      </div>
      <Button variant="primary">Let's go</Button>
    </div>
  );
}
window.LessonScreen = LessonScreen;
