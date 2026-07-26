import * as React from 'react';

/**
 * @startingPoint section="Components" subtitle="Wallet activity list row: allowance/deposit/withdrawal/loan/repayment" viewport="700x360"
 */
export interface ActivityRowProps {
  type?: 'allowance' | 'deposit' | 'withdrawal' | 'loan' | 'repayment';
  title: string;
  /** e.g. a date and reason: "Jul 21 · Weekly allowance". */
  subtitle: string;
  /** Formatted amount without sign/currency, e.g. "10.00". */
  amount: string;
  /** Whether this event increased the wallet (adds a "+" and green tint). Default true. */
  positive?: boolean;
  onClick?: () => void;
}
export function ActivityRow(props: ActivityRowProps): JSX.Element;
