import React from 'react';

export function BalanceDisplay({ amount, lastUpdated, notice }) {
  return (
    <div className="ewa-balance-hero">
      <span className="ewa-balance-label">Child's virtual balance</span>
      <span className="ewa-balance-num">US${amount}</span>
      <span className="ewa-balance-notice">{notice || 'Virtual practice only. These dollars are pretend, cannot be redeemed, and never move real money.'}</span>
      {lastUpdated ? <span className="ewa-balance-notice" style={{ color: 'var(--text-tertiary)' }}>Last updated {lastUpdated}</span> : null}
    </div>
  );
}
