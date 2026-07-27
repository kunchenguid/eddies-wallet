function App() {
  const [screen, setScreen] = React.useState('welcome');
  const [role, setRole] = React.useState('parent');
  const [pinOpen, setPinOpen] = React.useState(false);
  const [activityItem, setActivityItem] = React.useState(null);
  const [loanOpen, setLoanOpen] = React.useState(false);
  const [flow, setFlow] = React.useState(null);
  const [lessonOpen, setLessonOpen] = React.useState(false);
  const [activity, setActivity] = React.useState([
    { type: 'loan', title: 'Loan', subtitle: 'Jul 18 · Bike helmet', amount: '10.00', explain: 'Your parent gave you US$10.00 virtual dollars to use now, and US$10.00 to give back over time.' },
    { type: 'withdrawal', title: 'Withdrawal', subtitle: 'Jul 15 · Comic book', amount: '4.00', positive: false, explain: 'Your parent recorded that US$4.00 virtual dollars were used.' },
    { type: 'allowance', title: 'Allowance', subtitle: 'Jul 14 · Weekly', amount: '10.00', explain: 'Your parent added US$10.00 virtual dollars, your weekly allowance.' },
  ]);

  const handleRoleTap = (next) => {
    if (next === 'parent' && role !== 'parent') setPinOpen(true);
    else setRole(next);
  };

  const handleConfirm = (amount) => {
    const kind = flow;
    setFlow(null);
    const labels = { deposit: 'Deposit', withdrawal: 'Withdrawal', loan: 'Loan', repay: 'Repayment' };
    setActivity((a) => [{ type: kind === 'repay' ? 'repayment' : kind, title: labels[kind], subtitle: 'Just now', amount, positive: kind !== 'withdrawal' && kind !== 'repay', explain: 'Recorded by parent.' }, ...a]);
  };

  return (
    <IOSDevice title="Eddie's Wallet">
      <div style={{ position: 'relative', height: '100%' }}>
        {screen === 'welcome' ? (
          <WelcomeScreen onSignIn={() => setScreen('wallet')} />
        ) : lessonOpen ? (
          <LessonScreen onBack={() => setLessonOpen(false)} />
        ) : (
          <WalletScreen
            role={role}
            onRoleTap={handleRoleTap}
            activity={activity}
            onOpenActivity={setActivityItem}
            onOpenLoan={() => setLoanOpen(true)}
            onAction={setFlow}
            onLesson={() => setLessonOpen(true)}
          />
        )}
        {pinOpen ? <PinSheet onClose={() => setPinOpen(false)} onSuccess={() => { setRole('parent'); setPinOpen(false); }} /> : null}
        {activityItem ? <ActivityDetailSheet item={activityItem} onClose={() => setActivityItem(null)} /> : null}
        {loanOpen ? <LoanDetailSheet isParent={role === 'parent'} onClose={() => setLoanOpen(false)} onRepay={() => { setLoanOpen(false); setFlow('repay'); }} /> : null}
        {flow ? <MoneyFlowSheet kind={flow} onClose={() => setFlow(null)} onConfirm={handleConfirm} /> : null}
      </div>
    </IOSDevice>
  );
}
window.App = App;
