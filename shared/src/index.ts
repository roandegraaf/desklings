export type HealthResponse = {
  status: 'ok';
  setupRequired: boolean;
};

export type ProviderSettings = {
  baseUrl: string;
  model: string;
  apiKeySet: boolean;
};

export type ProviderSettingsUpdate = {
  baseUrl?: string;
  model?: string;
  apiKey?: string;
};

export type ApiError = {
  error: string;
};

export const MIN_PASSWORD_LENGTH = 8;

export type Agent = {
  id: number;
  name: string;
  display: number;
  createdAt: number;
};

export type ComputerActionName =
  | 'screenshot'
  | 'move'
  | 'click'
  | 'drag'
  | 'scroll'
  | 'type'
  | 'key'
  | 'clipboard_read'
  | 'clipboard_write';

export type ScrollDirection = 'up' | 'down' | 'left' | 'right';

export type ComputerAction =
  | { action: 'screenshot' }
  | { action: 'clipboard_read' }
  | { action: 'move'; x: number; y: number }
  | { action: 'click'; x: number; y: number; button: number }
  | { action: 'drag'; x: number; y: number; toX: number; toY: number; button: number }
  | { action: 'scroll'; x: number; y: number; direction: ScrollDirection; amount: number }
  | { action: 'type'; text: string }
  | { action: 'key'; keys: string }
  | { action: 'clipboard_write'; text: string };

/** A screenshot travels as base64 in JSON; see docs/architecture.md for why. */
export type ComputerResult = {
  action: ComputerActionName;
  image?: { mediaType: 'image/png'; base64: string };
  text?: string;
};

export type CommandRequest = {
  command: string;
  timeoutMs?: number;
  background?: boolean;
};

export type CommandResult = {
  exitCode: number;
  stdout: string;
  stderr: string;
  timedOut: boolean;
  background: boolean;
};
