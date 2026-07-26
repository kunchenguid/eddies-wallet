import * as React from 'react';

/**
 * @startingPoint section="Components" subtitle="Hero virtual-balance number with persistent nonredeemable notice" viewport="700x260"
 */
export interface BalanceDisplayProps {
  /** Formatted amount without the currency symbol, e.g. "24.00". */
  amount: string;
  /** Optional "Last updated …" stamp, shown when viewing a cached/offline snapshot. */
  lastUpdated?: string;
  /** Overrides the default virtual-money notice copy. */
  notice?: string;
}
export function BalanceDisplay(props: BalanceDisplayProps): JSX.Element;
