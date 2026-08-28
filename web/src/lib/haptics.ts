/** Short vibration on supported handsets; a no-op everywhere else. */
export function tap(pattern: number | number[] = 8) {
  if (typeof navigator === "undefined") return;
  const nav = navigator as Navigator & { vibrate?: (p: number | number[]) => boolean };
  try {
    nav.vibrate?.(pattern);
  } catch {
    /* blocked by the browser — ignore */
  }
}
