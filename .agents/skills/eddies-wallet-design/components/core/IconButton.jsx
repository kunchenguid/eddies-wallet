import React from 'react';

export function IconButton({ icon, variant = 'default', 'aria-label': ariaLabel, onClick, style, ...rest }) {
  const cls = ['ewa-iconbtn', variant === 'primary' ? 'ewa-iconbtn--primary' : ''].filter(Boolean).join(' ');
  return (
    <button className={cls} aria-label={ariaLabel} onClick={onClick} style={style} {...rest}>
      {icon}
    </button>
  );
}
