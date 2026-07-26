import React from 'react';
import { Icon } from '../core/Icon.jsx';

const CONFIG = {
  recorded: { cls: 'recorded', icon: 'circle-check', label: 'Recorded' },
  pending: { cls: 'pending', icon: 'clock', label: 'Waiting to sync' },
  rejected: { cls: 'rejected', icon: 'circle-alert', label: 'Not recorded' },
  draft: { cls: 'draft', icon: 'pencil', label: 'Draft on this iPad' }
};

export function StatusPill({ status = 'recorded', label }) {
  const c = CONFIG[status] || CONFIG.recorded;
  return (
    <span className={`ewa-pill ewa-pill--${c.cls}`}>
      <Icon name={c.icon} />
      {label || c.label}
    </span>
  );
}
