import * as React from 'react';

/**
 * @startingPoint section="Components" subtitle="Secondary open-loan card with progress + repay CTA" viewport="700x260"
 */
export interface LoanCardProps {
  /** Remaining principal, formatted without currency, e.g. "10.00". */
  remaining?: string;
  /** Original loan principal as a number, for progress-bar math. */
  total?: number;
  dueDate?: string;
  /** When true, shows the paid-off state instead of progress/repay. */
  paid?: boolean;
  onRepay?: () => void;
}
export function LoanCard(props: LoanCardProps): JSX.Element;
