import { ref, watch, computed } from 'vue';
import { trackReferencesObservable } from '@livekit/components-core';

/**
 * Observe track references (remote + local) for the given sources — replaces
 * LiveKitVoiceClient.getRemoteVideoTracks() and the bespoke 'video:track'
 * CustomEvent bus. Emits TrackReference[] ({participant, publication, source}).
 *
 * @param {import('vue').Ref<import('livekit-client').Room|null>} roomRef
 * @param {import('livekit-client').Track.Source[]} sources
 * @param {{ onlySubscribed?: boolean }} [options]
 */
export function useTracks(roomRef, sources, options = {}) {
  const trackRefs = ref([]);
  let subscription = null;

  watch(
    roomRef,
    room => {
      subscription?.unsubscribe?.();
      subscription = null;
      trackRefs.value = [];
      if (!room) return;
      subscription = trackReferencesObservable(room, sources, {
        onlySubscribed: options.onlySubscribed ?? false,
      }).subscribe(({ trackReferences }) => {
        trackRefs.value = trackReferences;
      });
    },
    { immediate: true }
  );

  // Convenience splits: remote vs local track references.
  const remoteTracks = computed(() =>
    trackRefs.value.filter(t => !t.participant?.isLocal)
  );
  const localTracks = computed(() =>
    trackRefs.value.filter(t => t.participant?.isLocal)
  );

  return { trackRefs, remoteTracks, localTracks };
}
