import React from 'react';
import { Icon } from '../core/Icon.jsx';

export function Input({ label, hint, error, leadingIcon, prefix, ...rest }) {
  return (
    <div className={`ewa-field${error ? ' is-error' : ''}`}>
      {label ? <label>{label}</label> : null}
      <div className="ewa-input-wrap">
        {leadingIcon ? <Icon name={leadingIcon} size={18} color="var(--text-tertiary)" /> : null}
        {prefix ? <span style={{ color: 'var(--text-tertiary)', font: 'var(--text-body-md-bold)' }}>{prefix}</span> : null}
        <input {...rest} />
      </div>
      {(error || hint) ? <span className="ewa-hint">{error || hint}</span> : null}
    </div>
  );
}
