export type IconName = 'meetings' | 'notes' | 'folder' | 'all' | 'plus' | 'search' | 'settings' | 'chevron' | 'close' | 'edit' | 'clock' | 'calendar' | 'check' | 'alert' | 'sidebar' | 'refresh' | 'import';
const paths: Record<IconName, React.ReactNode> = {
  meetings: <><path d="M3 9v6M7 5v14M11 2v20M15 7v10M19 5v14M23 9v6" /></>,
  notes: <><rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 8h8M8 12h8M8 16h5"/></>,
  folder: <path d="M3 7V5a2 2 0 0 1 2-2h5l2 3h7a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7h18"/>,
  all: <><path d="m3 13 3-8h12l3 8v7H3z"/><path d="M3 13h6l1 3h4l1-3h6M8 8h8"/></>,
  plus: <path d="M12 5v14M5 12h14"/>,
  import: <><path d="M12 3v12m-4-4 4 4 4-4"/><path d="M4 17v3h16v-3"/></>,
  search: <><circle cx="10" cy="10" r="7"/><path d="m15 15 6 6"/></>,
  settings: <><path d="M3 6h18M3 12h18M3 18h18"/><circle cx="8" cy="6" r="2"/><circle cx="16" cy="12" r="2"/><circle cx="9" cy="18" r="2"/></>,
  chevron: <path d="m9 5 7 7-7 7"/>, close: <path d="m6 6 12 12M18 6 6 18"/>,
  edit: <><path d="m14 5 5 5M4 20l5-1L21 7a2 2 0 0 0-5-5L4 14z"/><path d="M13 21H4v-8"/></>,
  clock: <><circle cx="12" cy="12" r="9"/><path d="M12 7v5l4 2"/></>,
  calendar: <><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M7 2v6M17 2v6M3 11h18M7 15h2M13 15h2"/></>,
  check: <path d="m5 12 4 4L20 5"/>, alert: <><circle cx="12" cy="12" r="9"/><path d="M12 7v6M12 17h.01"/></>,
  refresh: <><path d="M20 10a8 8 0 1 0-1 8M20 4v6h-6"/></>,
  sidebar: <><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16"/></>,
};
export default function Icon({ name, size = 18 }: { name: IconName; size?: number }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.65" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name]}</svg>;
}
