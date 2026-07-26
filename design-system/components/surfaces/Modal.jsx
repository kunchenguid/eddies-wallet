import React from 'react';

export function Modal({ open, onClose, title, children, footer }) {
  if (!open) return null;
  return (
    <div className="ewa-sheet-overlay" onClick={onClose}>
      <div className="ewa-sheet" onClick={(e) => e.stopPropagation()}>
        <div className="ewa-sheet-handle" />
        {title ? <h2 style={{ font: 'var(--text-heading-lg)', color: 'var(--text-primary)', margin: '0 0 16px' }}>{title}</h2> : null}
        {children}
        {footer ? <div style={{ marginTop: 24, display: 'flex', flexDirection: 'column', gap: 12 }}>{footer}</div> : null}
      </div>
    </div>
  );
}
