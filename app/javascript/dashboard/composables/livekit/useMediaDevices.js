import { ref, watch } from 'vue';
import {
  createMediaDeviceObserver,
  setupDeviceSelector,
} from '@livekit/components-core';
import { useObservable } from './useObservable';

/**
 * Enumerate + select media devices (mic / camera / speaker) via
 * @livekit/components-core observables — replaces the hand-rolled
 * getDevices()/switchDevice() on LiveKitVoiceClient.
 *
 * @param {'audioinput'|'audiooutput'|'videoinput'} kind
 * @param {import('vue').Ref<import('livekit-client').Room|null>} roomRef
 */
export function useMediaDevices(kind, roomRef) {
  // The available devices of this kind (updates as devices are plugged/unplugged).
  const devices = useObservable(
    () => createMediaDeviceObserver(kind, undefined, true),
    []
  );

  // The active device + a setter, bound to the room. Set up when the room exists.
  const activeDeviceId = ref('');
  let selector = null;

  watch(
    roomRef,
    room => {
      if (!room) {
        selector = null;
        return;
      }
      selector = setupDeviceSelector(kind, room);
      selector.activeDeviceObservable?.subscribe?.(id => {
        activeDeviceId.value = id;
      });
    },
    { immediate: true }
  );

  const setActiveDevice = async deviceId => {
    if (selector && deviceId) {
      await selector.setActiveMediaDevice(deviceId);
    }
  };

  return { devices, activeDeviceId, setActiveDevice };
}
