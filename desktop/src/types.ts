export interface FeatureFlags {
  cards: boolean;
  tasks: boolean;
  calendar: boolean;
  assistant: boolean;
  semanticSearch: boolean;
}
export interface Folder {
  id: string;
  name: string;
  revision: number;
  features?: FeatureFlags;
}
export interface Meeting {
  id: string;
  title: string;
  startedAt?: number | string;
  durationSeconds?: number;
  folderId?: string | null;
  hasTranscript?: boolean;
  hasSummary?: boolean;
}
export interface Note {
  id: string;
  title: string;
  text: string;
  folderId?: string | null;
  meetingId?: string | null;
  revision: number;
  updatedAt?: number | string;
}
export interface Capabilities {
  library: boolean;
  recording: boolean;
  calendar: boolean;
  assistant: boolean;
  cards: boolean;
  tasks: boolean;
}
export interface Workspace {
  folders: Folder[];
  meetings: Meeting[];
  notes: Note[];
  capabilities: Capabilities;
}
export interface TranscriptSegment {
  start: number;
  end?: number;
  speaker?: string;
  text: string;
}
export interface MeetingDetail {
  meeting: Meeting;
  transcript: TranscriptSegment[];
  summary?: string | null;
  notes: Note[];
}
export interface NoteInput {
  id?: string;
  title: string;
  text: string;
  folderId?: string | null;
  meetingId?: string | null;
  expectedRevision?: number;
}
export interface FolderInput {
  id?: string;
  name: string;
  expectedRevision?: number;
}
export interface SearchResult {
  kind: 'meeting' | 'transcript' | 'summary' | 'note';
  id: string;
  title: string;
  excerpt?: string;
  meetingId?: string | null;
  noteId?: string | null;
  start?: number;
  folderId?: string | null;
}
export interface SearchResponse {
  hits: SearchResult[];
  total: number;
  truncated: boolean;
}
export interface BridgeError {
  code: string;
  message: string;
}
export interface LibraryAPI {
  getWorkspace(): Promise<Workspace>;
  getMeeting(meetingId: string): Promise<MeetingDetail>;
  saveNote(input: NoteInput): Promise<Note>;
  saveFolder(input: FolderInput): Promise<Folder>;
  searchLibrary(query: string, folderId?: string): Promise<SearchResponse>;
}
