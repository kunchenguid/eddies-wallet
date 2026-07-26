import * as React from 'react';

/** A small colored label, e.g. event-type tag ("Allowance", "Loan") or an age-band tag. */
export interface BadgeProps {
  variant?: 'green' | 'gold' | 'peach' | 'neutral';
  icon?: React.ReactNode;
  children?: React.ReactNode;
}
export function Badge(props: BadgeProps): JSX.Element;
