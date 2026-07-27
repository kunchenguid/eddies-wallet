import * as React from 'react';

/**
 * @startingPoint section="Components" subtitle="Labeled text field with icon/prefix and error state" viewport="700x320"
 */
export interface InputProps {
  label?: string;
  /** Helper text shown below the field when there is no error. */
  hint?: string;
  /** Error text; also switches the field border/hint to the danger color. */
  error?: string;
  /** Name of an Icon (see Icon component) shown at the field's leading edge. */
  leadingIcon?: string;
  /** Fixed text shown before the input, e.g. "US$". */
  prefix?: string;
  value?: string | number;
  placeholder?: string;
  type?: string;
  onChange?: (e: React.ChangeEvent<HTMLInputElement>) => void;
}
export function Input(props: InputProps): JSX.Element;
