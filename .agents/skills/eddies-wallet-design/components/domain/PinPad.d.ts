import * as React from 'react';

/**
 * @startingPoint section="Components" subtitle="Numeric keypad + dot indicators for the parent PIN gate" viewport="700x420"
 */
export interface PinPadProps {
  /** PIN length, default 4. */
  length?: number;
  value?: string;
  onChange?: (next: string) => void;
}
export function PinPad(props: PinPadProps): JSX.Element;
