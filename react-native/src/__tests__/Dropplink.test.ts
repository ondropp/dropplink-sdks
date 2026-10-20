import type * as Api from '../index';

type Handler = (payload: unknown) => void;

// A minimal fake of the pieces of `react-native` the package touches.
function setup(options: { linked?: boolean; initialUrl?: string | null } = {}) {
  const { linked = true, initialUrl = null } = options;
  const eventHandlers = new Map<string, Set<Handler>>();
  const urlHandlers = new Set<(e: { url: string }) => void>();

  const nativeModule = {
    initializeSdk: jest.fn(() => Promise.resolve()),
    handleDeepLink: jest.fn((_url: string) => Promise.resolve()),
    getAttribution: jest.fn((): Promise<object | null> =>
      Promise.resolve(null)
    ),
    getInstallId: jest.fn((): Promise<string | null> => Promise.resolve(null)),
    setDeepLinkListenerEnabled: jest.fn(),
    addListener: jest.fn(),
    removeListeners: jest.fn(),
  };

  class NativeEventEmitter {
    constructor(public module: unknown) {}
    addListener(event: string, handler: Handler) {
      const set = eventHandlers.get(event) ?? new Set();
      eventHandlers.set(event, set);
      set.add(handler);
      return { remove: () => set.delete(handler) };
    }
  }

  const Linking = {
    getInitialURL: jest.fn(() => Promise.resolve(initialUrl)),
    addEventListener: jest.fn(
      (_type: 'url', handler: (e: { url: string }) => void) => {
        urlHandlers.add(handler);
        return { remove: () => urlHandlers.delete(handler) };
      }
    ),
  };

  const get = jest.fn((_name: string) => (linked ? nativeModule : null));

  jest.resetModules();
  jest.doMock('react-native', () => ({
    TurboModuleRegistry: { get },
    NativeEventEmitter,
    Linking,
    Platform: { select: (o: Record<string, string>) => o.default },
  }));
  const api: typeof Api = require('../index');

  return {
    api,
    nativeModule,
    get,
    Linking,
    emit: (event: string, payload: unknown) =>
      eventHandlers.get(event)?.forEach((h) => h(payload)),
    openUrl: (url: string) => urlHandlers.forEach((h) => h({ url })),
    urlHandlerCount: () => urlHandlers.size,
  };
}

const flush = () => new Promise<void>((resolve) => setImmediate(resolve));

describe('module lookup', () => {
  it('looks up the RNDropplink native module', () => {
    const { get } = setup();
    expect(get).toHaveBeenCalledWith('RNDropplink');
  });

  it('imports without throwing when not linked, and throws a helpful error on use', () => {
    const { api } = setup({ linked: false });
    expect(() => api.Dropplink.handleDeepLink('https://x')).toThrow(
      /doesn't seem to be linked/
    );
  });
});

describe('initialize', () => {
  it('fills in defaults: debug false, baseUrl null (native default)', async () => {
    const { api, nativeModule } = setup();
    await api.Dropplink.initialize({ keyId: 'ak_123', secret: 's3cret' });
    expect(nativeModule.initializeSdk).toHaveBeenCalledWith({
      keyId: 'ak_123',
      secret: 's3cret',
      debug: false,
      baseUrl: null,
    });
  });

  it('passes explicit values through and drops unknown keys', async () => {
    const { api, nativeModule } = setup();
    await api.Dropplink.initialize({
      keyId: 'ak_1',
      secret: 's',
      debug: true,
      baseUrl: 'http://10.0.2.2:4100',
      extra: 1,
    } as Parameters<typeof api.Dropplink.initialize>[0]);
    expect(nativeModule.initializeSdk).toHaveBeenCalledWith({
      keyId: 'ak_1',
      secret: 's',
      debug: true,
      baseUrl: 'http://10.0.2.2:4100',
    });
  });

  it('propagates a native rejection', async () => {
    const { api, nativeModule } = setup();
    nativeModule.initializeSdk.mockRejectedValueOnce(new Error('bad key'));
    await expect(
      api.Dropplink.initialize({ keyId: '', secret: '' })
    ).rejects.toThrow('bad key');
  });
});

describe('handleDeepLink', () => {
  it('forwards the url unchanged', async () => {
    const { api, nativeModule } = setup();
    await api.Dropplink.handleDeepLink('https://go.brand.com/abc?x=1');
    expect(nativeModule.handleDeepLink).toHaveBeenCalledWith(
      'https://go.brand.com/abc?x=1'
    );
  });
});

describe('getAttribution', () => {
  it('returns null before the first init', async () => {
    const { api } = setup();
    await expect(api.Dropplink.getAttribution()).resolves.toBeNull();
  });

  it('returns null for undefined from native', async () => {
    const { api, nativeModule } = setup();
    nativeModule.getAttribution.mockResolvedValueOnce(
      undefined as unknown as null
    );
    await expect(api.Dropplink.getAttribution()).resolves.toBeNull();
  });

  it('strips null optional fields', async () => {
    const { api, nativeModule } = setup();
    nativeModule.getAttribution.mockResolvedValueOnce({
      type: 'organic',
      method: 'none',
      clickId: null,
      linkId: null,
      confidence: null,
      attributedAt: null,
    });
    await expect(api.Dropplink.getAttribution()).resolves.toEqual({
      type: 'organic',
      method: 'none',
    });
  });

  it('keeps every attributed field', async () => {
    const { api, nativeModule } = setup();
    const attributed = {
      type: 'attributed',
      method: 'install_referrer',
      clickId: 'c_8b1f0e7d2a4c4f6e',
      linkId: '6711a0c2f1e4b8a9c3d2e1f0',
      campaignId: '6711a0c2f1e4b8a9c3d2e1f1',
      creatorId: '6711a0c2f1e4b8a9c3d2e1f2',
      source: 'instagram',
      confidence: 1,
      attributedAt: '2026-10-17T10:00:42.000Z',
    };
    nativeModule.getAttribution.mockResolvedValueOnce(attributed);
    await expect(api.Dropplink.getAttribution()).resolves.toEqual(attributed);
  });
});

describe('getInstallId', () => {
  it('returns the native id', async () => {
    const { api, nativeModule } = setup();
    nativeModule.getInstallId.mockResolvedValueOnce(
      '6f1c2a9e-3b7d-4c51-9a8e-2d4f6b1c0e73'
    );
    await expect(api.Dropplink.getInstallId()).resolves.toBe(
      '6f1c2a9e-3b7d-4c51-9a8e-2d4f6b1c0e73'
    );
  });

  it('maps undefined to null', async () => {
    const { api, nativeModule } = setup();
    nativeModule.getInstallId.mockResolvedValueOnce(
      undefined as unknown as null
    );
    await expect(api.Dropplink.getInstallId()).resolves.toBeNull();
  });
});

describe('addDeepLinkListener', () => {
  it('enables the native listener on the first add only', () => {
    const { api, nativeModule } = setup();
    const a = api.Dropplink.addDeepLinkListener(jest.fn());
    const b = api.Dropplink.addDeepLinkListener(jest.fn());
    expect(nativeModule.setDeepLinkListenerEnabled.mock.calls).toEqual([
      [true],
    ]);
    a.remove();
    b.remove();
  });

  it('disables the native listener when the last one is removed, once', () => {
    const { api, nativeModule } = setup();
    const a = api.Dropplink.addDeepLinkListener(jest.fn());
    const b = api.Dropplink.addDeepLinkListener(jest.fn());
    a.remove();
    a.remove(); // idempotent
    expect(nativeModule.setDeepLinkListenerEnabled).toHaveBeenLastCalledWith(
      true
    );
    b.remove();
    expect(nativeModule.setDeepLinkListenerEnabled.mock.calls).toEqual([
      [true],
      [false],
    ]);
    // Adding again re-enables, so native delivers anything it buffered meanwhile.
    api.Dropplink.addDeepLinkListener(jest.fn()).remove();
    expect(nativeModule.setDeepLinkListenerEnabled.mock.calls).toEqual([
      [true],
      [false],
      [true],
      [false],
    ]);
  });

  it('delivers converted deep links from the DropplinkDeepLink event', () => {
    const { api, emit } = setup();
    const listener = jest.fn();
    api.Dropplink.addDeepLinkListener(listener);

    emit('DropplinkDeepLink', {
      path: '/product/123',
      params: { ref: 'creator', variant: 'red' },
      url: null,
      isDeferred: true,
    });
    emit('DropplinkDeepLink', {
      path: '/product/123',
      params: null,
      url: 'https://go.brand.com/abc',
      isDeferred: false,
    });

    expect(listener.mock.calls).toEqual([
      [
        {
          path: '/product/123',
          params: { ref: 'creator', variant: 'red' },
          url: null,
          isDeferred: true,
        },
      ],
      [
        {
          path: '/product/123',
          params: {},
          url: 'https://go.brand.com/abc',
          isDeferred: false,
        },
      ],
    ]);
  });

  it('defaults a missing url to null and isDeferred to false', () => {
    const { api, emit } = setup();
    const listener = jest.fn();
    api.Dropplink.addDeepLinkListener(listener);
    emit('DropplinkDeepLink', { path: '/p', params: {} });
    expect(listener).toHaveBeenCalledWith({
      path: '/p',
      params: {},
      url: null,
      isDeferred: false,
    });
  });

  it('stops delivering after remove', () => {
    const { api, emit } = setup();
    const listener = jest.fn();
    api.Dropplink.addDeepLinkListener(listener).remove();
    emit('DropplinkDeepLink', { path: '/p', params: {}, isDeferred: false });
    expect(listener).not.toHaveBeenCalled();
  });
});

describe('listenToLinking', () => {
  it('forwards the launch URL and later url events to handleDeepLink', async () => {
    const { api, nativeModule, openUrl } = setup({
      initialUrl: 'https://go.brand.com/launch',
    });
    const stop = api.Dropplink.listenToLinking();
    await flush();
    openUrl('https://go.brand.com/later');

    expect(nativeModule.handleDeepLink.mock.calls).toEqual([
      ['https://go.brand.com/launch'],
      ['https://go.brand.com/later'],
    ]);
    stop();
  });

  it('ignores a null launch URL', async () => {
    const { api, nativeModule } = setup({ initialUrl: null });
    api.Dropplink.listenToLinking();
    await flush();
    expect(nativeModule.handleDeepLink).not.toHaveBeenCalled();
  });

  it('forwards the launch URL only once per JS context', async () => {
    const { api, nativeModule, Linking } = setup({
      initialUrl: 'https://go.brand.com/launch',
    });
    api.Dropplink.listenToLinking()();
    api.Dropplink.listenToLinking();
    await flush();
    expect(Linking.getInitialURL).toHaveBeenCalledTimes(1);
    // Delivered even though the first subscription was removed before it resolved (StrictMode).
    expect(nativeModule.handleDeepLink.mock.calls).toEqual([
      ['https://go.brand.com/launch'],
    ]);
  });

  it('unsubscribes from url events', () => {
    const { api, nativeModule, openUrl, urlHandlerCount } = setup();
    const stop = api.Dropplink.listenToLinking();
    expect(urlHandlerCount()).toBe(1);
    stop();
    expect(urlHandlerCount()).toBe(0);
    openUrl('https://go.brand.com/after');
    expect(nativeModule.handleDeepLink).not.toHaveBeenCalled();
  });

  it('swallows handleDeepLink and getInitialURL failures', async () => {
    const { api, nativeModule, Linking, openUrl } = setup();
    Linking.getInitialURL.mockRejectedValueOnce(new Error('no activity'));
    nativeModule.handleDeepLink.mockRejectedValue(new Error('native'));
    api.Dropplink.listenToLinking();
    openUrl('https://go.brand.com/x');
    await flush();
    expect(nativeModule.handleDeepLink).toHaveBeenCalledTimes(1);
  });
});
