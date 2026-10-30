/** Primary shortcuts follow the host OS and leave AltGr/alternate commands alone. */
type ShortcutEvent = Pick<KeyboardEvent, 'key' | 'ctrlKey' | 'metaKey' | 'altKey' | 'shiftKey'> & Partial<Pick<KeyboardEvent, 'code' | 'isComposing'>>;
export function isPrimaryShortcut(event: ShortcutEvent, key: string, platform: string): boolean {
  // Russian and other non-Latin input layouts still expose the physical KeyK/KeyS.
  // Keep logical Latin shortcuts (including alternate Latin layouts) authoritative.
  const matchesKey = event.key.toLowerCase() === key.toLowerCase()
    || (/^[^\u0000-\u007f]$/u.test(event.key) && event.code === `Key${key.toUpperCase()}`);
  if (event.isComposing || event.altKey || event.shiftKey || !matchesKey) return false;
  return platform.startsWith('Mac') ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey;
}
