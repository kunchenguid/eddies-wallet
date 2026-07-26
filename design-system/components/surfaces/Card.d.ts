import * as React from 'react';

/**
 * @startingPoint section="Components" subtitle="Base surface: default, flat, and alt-tint variants" viewport="700x260"
 */
export interface CardProps {
  /** "flat" drops the shadow (for nested cards); "alt" uses the tinted alt-surface background. Default is the standard elevated card. */
  variant?: 'flat' | 'alt';
  style?: React.CSSProperties;
  children?: React.ReactNode;
}
export function Card(props: CardProps): JSX.Element;
