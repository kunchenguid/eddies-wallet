import * as React from 'react';

/**
 * @startingPoint section="Components" subtitle="Recorded / waiting-to-sync / rejected / draft states, icon+text always paired" viewport="700x160"
 */
export interface StatusPillProps {
  /** Maps 1:1 to the PRD's sync-state vocabulary. Default "recorded". */
  status?: 'recorded' | 'pending' | 'rejected' | 'draft';
  /** Override the default label text. */
  label?: string;
}
export function StatusPill(props: StatusPillProps): JSX.Element;
