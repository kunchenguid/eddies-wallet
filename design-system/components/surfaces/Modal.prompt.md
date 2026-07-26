A bottom sheet for confirmation/review steps — "Review deposit before confirming", PIN setup, loan creation. Mount inside a `position: relative` screen container so the overlay covers just that screen.

```jsx
<Modal open={reviewing} onClose={() => setReviewing(false)} title="Review deposit"
  footer={<Button variant="primary">Confirm</Button>}>
  <p>US$10.00 will be added to the child's wallet.</p>
</Modal>
```
