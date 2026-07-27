The secondary loan card on the wallet — never a top-level "Loans" nav item per PRD. Shows remaining principal, a repay progress bar, and links to the repayment flow.

```jsx
<LoanCard remaining="6.00" total={10} dueDate="Aug 15" onRepay={openRepay} />
```

Paid-off loans stay visible via `paid` rather than disappearing.
