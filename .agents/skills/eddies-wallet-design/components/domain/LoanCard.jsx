import React from 'react';
import { Icon } from '../core/Icon.jsx';
import { Button } from '../core/Button.jsx';

export function LoanCard({ remaining, total, dueDate, paid = false, onRepay }) {
  const pct = total ? Math.round(((total - remaining) / total) * 100) : 0;
  return (
    <div className="ewa-loancard">
      <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
        <Icon name="hand-coins" size={22} color="var(--accent-peach-strong)" />
        <span style={{ font: 'var(--text-heading-md)', color: 'var(--text-primary)' }}>
          {paid ? 'Loan paid off' : `US$${remaining} left to repay`}
        </span>
      </div>
      {!paid ? (
        <>
          <div className="ewa-loan-track"><div className="ewa-loan-fill" style={{ width: `${pct}%` }} /></div>
          <span style={{ font: 'var(--text-body-sm)', color: 'var(--text-secondary)' }}>
            {dueDate ? `Due ${dueDate}` : 'No due date set'}
          </span>
          <Button variant="secondary" size="sm" onClick={onRepay}>Record repayment</Button>
        </>
      ) : (
        <span style={{ font: 'var(--text-body-sm)', color: 'var(--text-secondary)' }}>Kept in history as Paid.</span>
      )}
    </div>
  );
}
