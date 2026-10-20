/** Options for {@link Dropplink.initialize}. See docs/sdk-spec.md section 2. */
export type DropplinkConfig = {
  /** `ak_…` SDK key id for this platform, from the Dropplink dashboard. */
  keyId: string;
  /** The key's secret. Load it from build config; never commit it. */
  secret: string;
  /** Turns on native logging (tag `Dropplink`). Never ship `true`. Default `false`. */
  debug?: boolean;
  /** Defaults to `https://attribution.ondropp.app` (the native SDK's default). */
  baseUrl?: string;
};

/**
 * A resolved deep link: the deferred one after a fresh install (`isDeferred: true`, `url: null`)
 * or an App Link / Universal Link open (`isDeferred: false`, `url` set).
 */
export type DeepLink = {
  path: string;
  params: Record<string, string>;
  url: string | null;
  isDeferred: boolean;
};

/** The last attribution the server returned. */
export type Attribution = {
  type: 'attributed' | 'organic';
  method: 'install_referrer' | 'fingerprint' | 'none';
  clickId?: string;
  linkId?: string;
  campaignId?: string;
  creatorId?: string;
  source?: string;
  confidence?: number;
  /** ISO 8601 timestamp. */
  attributedAt?: string;
};

export type DeepLinkListener = (link: DeepLink) => void;

export type Subscription = { remove(): void };
