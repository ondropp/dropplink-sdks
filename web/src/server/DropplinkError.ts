/**
 * A request Dropplink refused or couldn't answer. `code` is the server's (`invalid_key`, `rate_limited`,
 * `storage_unavailable`, …) or `network_error` / `timeout`. Resending the same events is always safe:
 * `eventId` makes them idempotent.
 */
export class DropplinkError extends Error {
  readonly status: number | null;
  readonly code: string;
  readonly details: { path: string; message: string }[];

  constructor(status: number | null, code: string, message: string, details: { path: string; message: string }[] = []) {
    super(message);
    this.name = 'DropplinkError';
    this.status = status;
    this.code = code;
    this.details = details;
  }

  /** Worth retrying: rate limits, server errors and the network. */
  get retryable(): boolean {
    return this.status === null || this.status === 429 || this.status >= 500;
  }
}
