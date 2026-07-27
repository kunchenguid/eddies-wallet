import React from 'react';

export function Toggle({ on, onChange, 'aria-label': ariaLabel }) {
  return (
    <button className={`ewa-toggle${on ? ' is-on' : ''}`} role="switch" aria-checked={on} aria-label={ariaLabel} onClick={() => onChange && onChange(!on)}>
      <span className="ewa-toggle-thumb" />
    </button>
  );
}
