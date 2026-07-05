import { ref, readonly, onMounted, onUnmounted } from 'vue';

/**
 * Adapt an RxJS Observable (from @livekit/components-core) to a Vue ref.
 * The observable factory is called on mount so the Room is available; the
 * subscription is torn down on unmount. Returns a readonly ref that tracks
 * the latest emitted value.
 *
 * @param {() => import('rxjs').Observable<T> | null | undefined} observableFactory
 * @param {T} initialValue
 * @returns {Readonly<import('vue').Ref<T>>}
 */
export function useObservable(observableFactory, initialValue) {
  const state = ref(initialValue);
  let subscription = null;

  onMounted(() => {
    const observable = observableFactory();
    subscription = observable?.subscribe?.(value => {
      state.value = value;
    });
  });

  onUnmounted(() => {
    subscription?.unsubscribe?.();
    subscription = null;
  });

  return readonly(state);
}
