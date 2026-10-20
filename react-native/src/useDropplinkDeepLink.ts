import { useEffect, useRef } from 'react';
import { Dropplink } from './Dropplink';
import type { DeepLinkListener } from './types';

/**
 * Calls `handler` for every Dropplink deep link while the component is mounted. The latest
 * `handler` is always used, so it doesn't need to be memoised.
 */
export function useDropplinkDeepLink(handler: DeepLinkListener): void {
  const ref = useRef(handler);
  useEffect(() => {
    ref.current = handler;
  });

  useEffect(() => {
    const sub = Dropplink.addDeepLinkListener((link) => ref.current(link));
    return () => sub.remove();
  }, []);
}
