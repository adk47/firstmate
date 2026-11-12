// Capture-and-restore for the order address write (captain inbox 021/023).
//
// The rule: an action is only reversible if the PRIOR state was captured BEFORE the write,
// from the live store, and the restore is proven to reproduce it byte-for-byte. A revert
// that re-derives the old address from anything but the capture is not a revert.
export interface OrderRecipient {
  name: string;
  phone: string;
  line1: string;
  line2?: string;
  city: string;
  state?: string;
  postcode: string;
  country: string;
  company?: string;
}

export interface OrderAddressStore {
  read(orderRef: string): Promise<OrderRecipient>;
  write(orderRef: string, recipient: OrderRecipient): Promise<void>;
}

export interface CapturedAddress {
  orderRef: string;
  recipient: OrderRecipient;
  capturedAt: string;
}

const FIELDS: (keyof OrderRecipient)[] = [
  "name", "phone", "line1", "line2", "city", "state", "postcode", "country", "company",
];

/** Byte-for-byte comparison over the fields the write can touch. */
export function sameRecipient(a: OrderRecipient, b: OrderRecipient): boolean {
  return FIELDS.every((f) => (a[f] ?? "") === (b[f] ?? ""));
}

export function diffRecipient(a: OrderRecipient, b: OrderRecipient): string[] {
  return FIELDS.filter((f) => (a[f] ?? "") !== (b[f] ?? ""));
}

export async function captureAddress(store: OrderAddressStore, orderRef: string, now = new Date()): Promise<CapturedAddress> {
  const recipient = await store.read(orderRef);
  if (!recipient || !recipient.line1) {
    // A capture that did not read a real address cannot be a revert point.
    throw new Error(`capture failed: no address on order ${orderRef}`);
  }
  return { orderRef, recipient: { ...recipient }, capturedAt: now.toISOString() };
}

export async function restoreAddress(store: OrderAddressStore, captured: CapturedAddress): Promise<{ restored: boolean; mismatched: string[] }> {
  await store.write(captured.orderRef, captured.recipient);
  const after = await store.read(captured.orderRef);
  const mismatched = diffRecipient(captured.recipient, after);
  return { restored: mismatched.length === 0, mismatched };
}
