import React from 'react';

export function Badge({ variant = 'neutral', icon, children }) {
  return <span className={`ewa-badge ewa-badge--${variant}`}>{icon}{children}</span>;
}
