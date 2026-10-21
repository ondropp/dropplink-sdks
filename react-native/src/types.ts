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

/**
 * Properties for {@link Dropplink.track}. At most 20; keys `^[A-Za-z0-9_]{1,40}$`. The native SDK
 * drops invalid keys and values (and anything that looks like an email or phone number).
 */
export type EventProps = Record<string, string | number | boolean | null>;

/**
 * Revenue the app reports with an event, shown as app-reported in the dashboard. Purchases that pay
 * creators should come from the brand's server (`/v1/s2s/events`) instead.
 */
export type Revenue = {
  /** Finite and >= 0; rounded to 2 decimals natively. */
  amount: number;
  /** ISO 4217 code, e.g. `INR`. */
  currency: string;
  /** 1–128 chars. */
  orderId?: string;
};

/** Optional traits for {@link Dropplink.identify}. Hashed (SHA-256) on the device before sending. */
export type IdentifyTraits = {
  email?: string;
  /** E.164, e.g. `+919812345678`. */
  phone?: string;
};
