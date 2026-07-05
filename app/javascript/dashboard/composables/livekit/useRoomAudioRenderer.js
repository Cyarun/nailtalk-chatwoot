import { watch, onUnmounted } from 'vue';
import { Track } from 'livekit-client';
import { useTracks } from './useTracks';

/**
 * Play remote participants' audio — the framework-agnostic equivalent of
 * LiveKit's React <RoomAudioRenderer>. components-core has no audio-attach
 * helper, so we attach each remote audio TrackReference to a hidden <audio>
 * element (what the React component does internally), driven by the
 * trackReferencesObservable instead of a raw RoomEvent.TrackSubscribed listener.
 *
 * @param {import('vue').Ref<import('livekit-client').Room|null>} roomRef
 */
export function useRoomAudioRenderer(roomRef) {
  const { remoteTracks } = useTracks(roomRef, [Track.Source.Microphone], {
    onlySubscribed: true,
  });
  const attached = new Map(); // publication.trackSid -> HTMLAudioElement

  const detachAll = () => {
    attached.forEach(el => el.remove());
    attached.clear();
  };

  watch(
    remoteTracks,
    refs => {
      const liveSids = new Set();
      refs.forEach(ref => {
        const track = ref.publication?.audioTrack;
        const sid = ref.publication?.trackSid;
        if (!track || !sid) return;
        liveSids.add(sid);
        if (attached.has(sid)) return;
        const el = track.attach();
        el.autoplay = true;
        el.setAttribute('data-livekit-audio', 'true');
        document.body.appendChild(el);
        attached.set(sid, el);
      });
      // Remove elements for tracks that are gone.
      attached.forEach((el, sid) => {
        if (!liveSids.has(sid)) {
          el.remove();
          attached.delete(sid);
        }
      });
    },
    { deep: false }
  );

  onUnmounted(detachAll);

  return { detachAll };
}
