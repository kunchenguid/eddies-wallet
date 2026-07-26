import React from 'react';

export function Card({ variant, style, children, ...rest }) {
  const cls = ['ewa-card', variant ? `ewa-card--${variant}` : ''].filter(Boolean).join(' ');
  return <div className={cls} style={style} {...rest}>{children}</div>;
}
