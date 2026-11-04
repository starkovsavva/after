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
  durationSeconds?: number | null;
  folderId?: string | null;
  hasTranscript?: boolean;
  hasSummary?: boolean;
  hasMedia?: boolean;
  mediaKind?: 'audio' | 'video' | null;
}
export interface RecordingStatus { sessionId: string | null; phase: string; mode: string | null; elapsedMs: number; warning: string | null }
export interface RecoverableRecording { sessionId: string; bytes: number }
export interface SavedRecording { meeting: Meeting; interrupted: boolean }
export interface Note {
  id: string;
  title: string;
  text: string;
  folderId?: string | null;
  meetingId?: string | null;
  revision: number;
  updatedAt?: number | string;
}
export type RecordingMode = 'microphone' | 'microphone_and_system';
export interface Capabilities {
  speechChecks?: boolean;
  speechTranscription?: boolean;
  speechSelection?: boolean;
  library: boolean;
  import: boolean;
  recording: boolean; recordingRecovery?: boolean; recordingModes?: RecordingMode[];
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
export interface SpeechCheck { id: string; state: 'queued' | 'running' | 'succeeded' | 'failed' | 'cancelled' | 'interrupted' | 'blocked'; progress: number; attempt: number; cancelRequested: boolean; createdAt: number | null; }
export interface Transcription extends SpeechCheck { meetingId: string | null }
export interface SpeechSelectionStatus { revision: string; local: boolean }
export interface SpeechModelCandidate { generation: string; modelId: string }
export interface SpeechModelConfiguration { selection: SpeechSelectionStatus; candidate: SpeechModelCandidate | null }
export interface LibraryAPI {
  getSpeechModelConfiguration(): Promise<SpeechModelConfiguration>;
  selectManagedSpeechModel(generation: string, expectedRevision: string): Promise<SpeechSelectionStatus>;
  transcriptionStatus(meetingId: string): Promise<Transcription | null>;
  startTranscription(meetingId: string): Promise<Transcription>;
  resumeTranscription(meetingId: string, jobId: string, expectedAttempt: number): Promise<Transcription>;
  cancelTranscription(meetingId: string, jobId: string, expectedAttempt: number): Promise<Transcription>;
  speechCheckStatus(): Promise<SpeechCheck | null>;
  startSpeechCheck(): Promise<SpeechCheck>;
  cancelSpeechCheck(jobId: string, expectedAttempt: number): Promise<SpeechCheck>;
  getWorkspace(): Promise<Workspace>;
  getMeeting(meetingId: string): Promise<MeetingDetail>;
  chooseAndImport(): Promise<Meeting | null>;
  importStatus(): Promise<ImportStatus>;
  importHistory(after?: ImportHistoryCursor): Promise<ImportHistory>;
  resumeImport(jobId: string, expectedAttempt: number): Promise<Meeting | null>;
  cancelQueuedImport(jobId: string, expectedAttempt: number): Promise<void>;
  cancelImport(operationId: string, controlId: string): Promise<ImportStatus>;
  startRecording(mode: 'microphone' | 'microphone_and_system'): Promise<RecordingStatus>;
  recordingStatus(): Promise<RecordingStatus>;
  stopRecording(title: string): Promise<SavedRecording>;
  recoverableRecordings(): Promise<RecoverableRecording[]>;
  recoverRecording(sessionId: string): Promise<SavedRecording>;
  saveNote(input: NoteInput): Promise<Note>;
  saveFolder(input: FolderInput): Promise<Folder>;
  searchLibrary(query: string, folderId?: string): Promise<SearchResponse>;
}
export type ImportJobState = 'queued' | 'running' | 'succeeded' | 'failed' | 'cancelled' | 'interrupted' | 'blocked';
export interface ImportHistoryEntry {
  jobId: string;
  operationId: string;
  state: ImportJobState;
  progress: number;
  attempt: number;
  cancelRequested: boolean;
}
export interface ImportHistoryCursor { createdAt: number; id: string; }
export interface ImportHistory { jobs: ImportHistoryEntry[]; total: number; hasMore: boolean; nextCursor: ImportHistoryCursor | null; }
export interface ImportStatus {
  controlId: string | null;
  progress?: number | null;
  operationId: string | null;
  phase: 'idle' | 'choosing' | 'copying' | 'committing' | 'completed' | 'cancelled' | 'failed';
  copiedBytes: number;
  totalBytes: number;
  cancelRequested: boolean;
}
