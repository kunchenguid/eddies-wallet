import * as React from 'react';

/** A circular icon-only tap target (44px, meets minimum touch-target size). */
export interface IconButtonProps {
  icon: React.ReactNode;
  variant?: 'default' | 'primary';
  'aria-label': string;
  onClick?: () => void;
  style?: React.CSSProperties;
}
export function IconButton(props: IconButtonProps): JSX.Element;
