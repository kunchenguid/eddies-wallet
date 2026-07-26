import React from 'react';
import { ICONS } from './icon-data.js';

export function Icon({ name, size = 24, color, style, ...rest }) {
  const markup = ICONS[name];
  if (!markup) return null;
  return React.createElement('span', {
    className: 'ewa-icon',
    style: { width: size, height: size, color, ...style },
    dangerouslySetInnerHTML: {
      __html: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${markup}</svg>`
    },
    ...rest
  });
}
