import React from 'react';

export function Button({ variant = 'primary', size = 'md', disabled, icon, children, onClick, style, ...rest }) {
  const cls = ['ewa-btn', `ewa-btn--${variant}`, size === 'sm' ? 'ewa-btn--sm' : ''].filter(Boolean).join(' ');
  return (
    <button className={cls} disabled={disabled} onClick={onClick} style={style} {...rest}>
      {icon}
      {children}
    </button>
  );
}
