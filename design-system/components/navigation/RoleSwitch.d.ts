import * as React from 'react';

/**
 * @startingPoint section="Components" subtitle="Parent / Eddie's-view segmented switch" viewport="700x140"
 */
export interface RoleSwitchProps {
  role: 'parent' | 'child';
  onChange?: (role: 'parent' | 'child') => void;
}
export function RoleSwitch(props: RoleSwitchProps): JSX.Element;
