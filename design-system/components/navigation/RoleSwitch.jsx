import React from 'react';

export function RoleSwitch({ role, onChange }) {
  return (
    <div className="ewa-roleswitch" role="tablist">
      <button className={role === 'parent' ? 'is-active' : ''} onClick={() => onChange && onChange('parent')}>Parent</button>
      <button className={role === 'child' ? 'is-active' : ''} onClick={() => onChange && onChange('child')}>Eddie's view</button>
    </div>
  );
}
