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
