import { ref, watch } from 'vue';
import { Track } from 'livekit-client';
import { setupMediaToggle, observeParticipantMedia } from '@livekit/components-core';

/**
 * Local participant mic + camera state and toggles, via components-core —
 * replaces LiveKitVoiceClient.setMuted()/setCameraEnabled()/isCameraEnabled().
 *
 * @param {import('vue').Ref<import('livekit-client').Room|null>} roomRef
 */
export function useLocalMedia(roomRef) {
  const isMicEnabled = ref(true);
  const isCameraEnabled = ref(false);

  let micToggle = null;
  let cameraToggle = null;
  const subs = [];

  const teardown = () => {
    subs.forEach(s => s?.unsubscribe?.());
    subs.length = 0;
    micToggle = null;
    cameraToggle = null;
  };

  watch(
    roomRef,
    room => {
      teardown();
      if (!room) return;

      micToggle = setupMediaToggle(Track.Source.Microphone, room);
      cameraToggle = setupMediaToggle(Track.Source.Camera, room);

      // Keep the reactive state in sync with the room's actual media state.
      subs.push(
        observeParticipantMedia(room.localParticipant).subscribe(media => {
          isMicEnabled.value = media.isMicrophoneEnabled;
          isCameraEnabled.value = media.isCameraEnabled;
        })
      );
    },
    { immediate: true }
  );

  // Mute = disable mic (forceState false); unmute = enable (true).
  const setMuted = async shouldMute => {
    if (micToggle) await micToggle.toggle(!shouldMute);
  };
  const setCameraEnabled = async enabled => {
    if (cameraToggle) await cameraToggle.toggle(enabled);
  };

  return { isMicEnabled, isCameraEnabled, setMuted, setCameraEnabled };
}
