import React from 'react';
import { Icon } from '../core/Icon.jsx';

const TYPE_CONFIG = {
  allowance: { icon: 'gift', bg: 'var(--accent-gold-tint)', fg: 'var(--gold-700)' },
  deposit: { icon: 'circle-arrow-down', bg: 'var(--state-success-tint)', fg: 'var(--green-700)' },
  withdrawal: { icon: 'circle-arrow-up', bg: 'var(--ink-100)', fg: 'var(--text-secondary)' },
  loan: { icon: 'hand-coins', bg: 'var(--accent-peach-tint)', fg: 'var(--accent-peach-strong)' },
  repayment: { icon: 'repeat', bg: 'var(--state-success-tint)', fg: 'var(--green-700)' }
};

export function ActivityRow({ type = 'deposit', title, subtitle, amount, positive = true, onClick }) {
  const c = TYPE_CONFIG[type] || TYPE_CONFIG.deposit;
  return (
    <div className="ewa-activity-row" onClick={onClick} style={{ cursor: onClick ? 'pointer' : 'default' }}>
      <span className="ewa-activity-icon" style={{ background: c.bg, color: c.fg }}>
        <Icon name={c.icon} size={20} />
      </span>
      <div>
        <div className="ewa-activity-title">{title}</div>
        <div className="ewa-activity-sub">{subtitle}</div>
      </div>
      <span className="ewa-activity-amt" style={{ color: positive ? 'var(--green-700)' : 'var(--text-primary)' }}>
        {positive ? '+' : '-'}US${amount}
      </span>
      {onClick ? <Icon name="chevron-right" size={18} color="var(--text-tertiary)" /> : null}
    </div>
  );
}
