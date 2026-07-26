function WelcomeScreen({ onSignIn }) {
  const { Icon } = window.EddieSWalletDesignSystem_b072eb;
  return (
    <div style={{ height: '100%', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'space-between', padding: '48px 28px 40px', background: 'var(--surface-app)', boxSizing: 'border-box', textAlign: 'center' }}>
      <div />
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 20 }}>
        <div className="ewa-float" style={{ width: 100, height: 100, borderRadius: '50%', background: 'var(--green-500)', display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: 'var(--shadow-md)' }}>
          <Icon name="piggy-bank" size={52} color="var(--white)" />
        </div>
        <div style={{ font: '700 32px var(--font-display)', color: 'var(--text-primary)' }}>Eddie's Wallet</div>
        <div style={{ font: 'var(--text-body-lg)', color: 'var(--text-secondary)', maxWidth: 300 }}>
          A pretend wallet for practicing allowance, spending, and borrowing.
        </div>
        <div style={{ font: 'var(--text-body-sm)', color: 'var(--text-tertiary)', maxWidth: 280, background: 'var(--surface-card-alt)', padding: '12px 16px', borderRadius: 16 }}>
          Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.
        </div>
      </div>
      <div style={{ width: '100%', display: 'flex', flexDirection: 'column', gap: 12 }}>
        <button onClick={onSignIn} style={{ height: 52, borderRadius: 14, background: '#000', color: '#fff', border: 'none', font: '600 17px -apple-system,sans-serif', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8 }}>
           Sign in with Apple
        </button>
        <div style={{ font: 'var(--text-caption)', color: 'var(--text-tertiary)' }}>Parent sign-in only — Eddie doesn't need an account.</div>
      </div>
    </div>
  );
}
window.WelcomeScreen = WelcomeScreen;
