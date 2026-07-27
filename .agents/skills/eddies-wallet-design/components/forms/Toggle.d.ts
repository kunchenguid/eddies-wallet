import * as React from 'react';

/** A simple on/off switch, e.g. for allowance rule enabled/paused. */
export interface ToggleProps {
  on: boolean;
  onChange?: (next: boolean) => void;
  'aria-label': string;
}
export function Toggle(props: ToggleProps): JSX.Element;
