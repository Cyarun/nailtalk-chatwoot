<script setup>
// Video tiles for an internal (agent<->agent) LiveKit call. Listens for the
// LiveKitVoiceClient's 'video:track' events (emitted on TrackSubscribed(video) and when
// the local camera is enabled) and attaches each LiveKit VideoTrack to a <video> element.
// Local (self-view) is shown small; remote fills the tile. Only mounted when video is on.
import { ref, onMounted, onBeforeUnmount } from 'vue';
import LiveKitVoiceClient from 'dashboard/api/channel/voice/livekitVoiceClient';

const remoteEl = ref(null);
const localEl = ref(null);
let attached = [];

const attachTrack = (track, remote) => {
  if (!track) return;
  const target = remote ? remoteEl.value : localEl.value;
  if (!target) return;
  target.innerHTML = ''; // replace any previous track in this tile
  const el = track.attach();
  el.autoplay = true;
  el.playsInline = true;
  if (!remote) el.muted = true; // never echo our own audio via the self-view
  el.classList.add('w-full', 'h-full', 'object-cover', 'rounded-lg');
  target.appendChild(el);
  attached.push({ track, el });
};

const onVideoTrack = event => {
  const { track, remote } = event.detail || {};
  attachTrack(track, remote);
};

onMounted(() => {
  // Attach any video tracks that ALREADY exist (the remote/local track may have been
  // published before this component mounted, so its 'video:track' event was missed).
  LiveKitVoiceClient.getRemoteVideoTracks().forEach(t => attachTrack(t, true));
  const local = LiveKitVoiceClient.getLocalVideoTrack();
  if (local) attachTrack(local, false);
  // ...then listen for future tracks (camera toggled on, other side joins video).
  LiveKitVoiceClient.addEventListener('video:track', onVideoTrack);
});

onBeforeUnmount(() => {
  LiveKitVoiceClient.removeEventListener('video:track', onVideoTrack);
  attached.forEach(({ track }) => track.detach().forEach(el => el.remove()));
  attached = [];
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
