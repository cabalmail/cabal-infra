/**
 * Insert a value into a host-page input the way the platform recommends so
 * framework-controlled inputs (React et al.) observe the change: use the
 * native value setter (React patches the instance property), then dispatch
 * `input` and `change`.
 */

export function insertValue(field: HTMLInputElement, value: string): void {
  field.focus();
  const nativeSetter = Object.getOwnPropertyDescriptor(
    HTMLInputElement.prototype,
    'value',
  )?.set;
  if (nativeSetter) {
    nativeSetter.call(field, value);
  } else {
    field.value = value;
  }
  field.dispatchEvent(new Event('input', { bubbles: true }));
  field.dispatchEvent(new Event('change', { bubbles: true }));
  field.blur();
}
