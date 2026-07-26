import React from 'react';

export function PinPad({ length = 4, value = '', onChange }) {
  const press = (d) => { if (value.length < length) onChange && onChange(value + d); };
  const back = () => onChange && onChange(value.slice(0, -1));
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 32, alignItems: 'center' }}>
      <div className="ewa-pindots">
        {Array.from({ length }).map((_, i) => (
          <span key={i} className={`dot${i < value.length ? ' is-filled' : ''}`} />
        ))}
      </div>
      <div className="ewa-pinpad">
        {['1','2','3','4','5','6','7','8','9'].map((d) => (
          <button key={d} onClick={() => press(d)}>{d}</button>
        ))}
        <span />
        <button onClick={() => press('0')}>0</button>
        <button onClick={back} aria-label="Delete" style={{ fontSize: 16 }}>⌫</button>
      </div>
    </div>
  );
}
