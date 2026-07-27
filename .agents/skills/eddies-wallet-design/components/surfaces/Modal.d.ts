import * as React from 'react';

/** A bottom sheet (iOS-style) used for review/confirm steps — deposit review, PIN setup, loan creation. Positions relative to a `position:relative` container. */
export interface ModalProps {
  open: boolean;
  onClose?: () => void;
  title?: string;
  children?: React.ReactNode;
  /** Action buttons, typically <Button> elements stacked vertically. */
  footer?: React.ReactNode;
}
export function Modal(props: ModalProps): JSX.Element;
