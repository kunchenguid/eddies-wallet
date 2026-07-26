import * as React from 'react';

/** Inline icon from the brand's Lucide-derived icon set (see readme Iconography section for the full name list). */
export interface IconProps {
  /** Icon name, e.g. "wallet", "piggy-bank", "circle-check". See assets/icons/ for the full set. */
  name: string;
  /** Pixel size (width and height). Default 24. */
  size?: number;
  /** CSS color; defaults to inherited text color (icons use stroke="currentColor"). */
  color?: string;
  style?: React.CSSProperties;
}
export function Icon(props: IconProps): JSX.Element;
