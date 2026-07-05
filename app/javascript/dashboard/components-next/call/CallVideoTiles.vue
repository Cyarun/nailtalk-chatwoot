<script setup>
// Video tiles for an internal (agent<->agent) LiveKit call, driven by the components-core
// composable layer (Option B) — replaces the hand-rolled 'video:track' CustomEvent bus +
// LiveKitVoiceClient.getRemoteVideoTracks/getLocalVideoTrack. useTracks emits the current
// camera TrackReferences (remote + local) as an RxJS-backed reactive ref; we attach each
// to a <video> element and keep the DOM in sync as tracks come and go.
import { watch, onBeforeUnmount, ref } from 'vue';
import { Track } from 'livekit-client';
import { liveKitRoomRef } from 'dashboard/api/channel/voice/livekitVoiceClient';
import { useTracks } from 'dashboard/composables/livekit/useTracks';

const remoteEl = ref(null);
const localEl = ref(null);

const { remoteTracks, localTracks } = useTracks(liveKitRoomRef, [Track.Source.Camera], {
  onlySubscribed: false,
});

// Attach the first track of a list into a tile element (1:1 call → one remote, one local).
const syncTile = (target, trackRefs, { muted }) => {
  if (!target) return;
  const track = trackRefs[0]?.publication?.videoTrack;
  target.innerHTML = ''; // replace whatever was there
  if (!track) return;
  const el = track.attach();
  el.autoplay = true;
  el.playsInline = true;
  if (muted) el.muted = true; // never echo our own audio via the self-view
  el.classList.add('w-full', 'h-full', 'object-cover', 'rounded-lg');
  target.appendChild(el);
};

watch(
  remoteTracks,
  refs => syncTile(remoteEl.value, refs, { muted: false }),
  { immediate: true }
);
watch(
  localTracks,
  refs => syncTile(localEl.value, refs, { muted: true }),
  { immediate: true }
);

onBeforeUnmount(() => {
  // Detach any attached media elements so we don't leak them.
  [remoteEl.value, localEl.value].forEach(el => {
    if (el) el.innerHTML = '';
  });
});
</script>

<template>
  <div class="relative w-full h-48 bg-n-slate-3 rounded-lg overflow-hidden mx-4">
    <!-- Remote video fills the tile -->
    <div ref="remoteEl" class="w-full h-full flex items-center justify-center">
      <span class="text-body-main text-n-slate-11">Waiting for video…</span>
    </div>
    <!-- Local self-view, small, bottom-right -->
    <div
      ref="localEl"
      class="absolute bottom-2 right-2 w-20 h-28 bg-n-slate-4 rounded-lg overflow-hidden border border-n-slate-6"
    />
  </div>
</template>
