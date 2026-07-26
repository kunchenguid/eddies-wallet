import * as React from 'react';

/**
 * @startingPoint section="Components" subtitle="Primary action button, 3 variants" viewport="700x260"
 */
export interface ButtonProps {
  /** Visual style. primary = brand green fill; secondary = neutral fill; ghost = text-only; danger = destructive red. Default "primary". */
  variant?: 'primary' | 'secondary' | 'ghost' | 'danger';
  /** Default "md" (52px tall, for primary flows). "sm" is 40px, for inline/secondary actions. */
  size?: 'md' | 'sm';
  disabled?: boolean;
  /** Optional leading <Icon /> element. */
  icon?: React.ReactNode;
  children?: React.ReactNode;
  onClick?: () => void;
  style?: React.CSSProperties;
}
export function Button(props: ButtonProps): JSX.Element;
