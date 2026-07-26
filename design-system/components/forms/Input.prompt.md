A labeled text field for amounts, reasons, nicknames. Pair with `prefix="US$"` for money amounts.

```jsx
<Input label="Amount" prefix="US$" placeholder="0.00" hint="How much to add to Eddie's wallet" />
```

Use `error` instead of `hint` to show a validation message (e.g. "Can't withdraw more than the wallet balance").
