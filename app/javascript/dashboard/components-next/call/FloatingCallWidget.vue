<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useStore } from 'vuex';
import { useCallSession } from 'dashboard/composables/useCallSession';
import { setWhatsappCallMuted } from 'dashboard/composables/useWhatsappCallSession';
import TwilioVoiceClient from 'dashboard/api/channel/voice/twilioVoiceClient';
import LiveKitVoiceClient, {
  liveKitRoomRef,
} from 'dashboard/api/channel/voice/livekitVoiceClient';
import { useMediaDevices } from 'dashboard/composables/livekit/useMediaDevices';
import { useTracks } from 'dashboard/composables/livekit/useTracks';
import { Track } from 'livekit-client';
import { useAlert } from 'dashboard/composables';
import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import { useCallsStore } from 'dashboard/stores/calls';
import { frontendURL, conversationUrl } from 'dashboard/helper/URLHelper';
import { VOICE_CALL_PROVIDERS } from 'dashboard/helper/inbox';
import { VOICE_CALL_DIRECTION } from 'dashboard/components-next/message/constants';
import WindowVisibilityHelper from 'dashboard/helper/AudioAlerts/WindowVisibilityHelper';
import CallCard from 'dashboard/components-next/call/CallCard.vue';
import CallVideoTiles from 'dashboard/components-next/call/CallVideoTiles.vue';
import countriesList from 'shared/constants/countries.js';

const RINGTONE_URL = '/audio/dashboard/ringtone.mp3';

const route = useRoute();
const router = useRouter();
const store = useStore();

const {
  activeCall,
  incomingCalls,
  hasActiveCall,
  isJoining,
  joinCall,
  endCall: endCallSession,
  rejectIncomingCall,
  dismissCall,
  formattedCallDuration,
} = useCallSession();

// Mute routes by provider: WhatsApp toggles the local mic track, Twilio uses
// the Voice SDK connection's native mute. Both surface the same button.
const isMuted = ref(false);
const isWhatsappActive = computed(
  () => activeCall.value?.provider === VOICE_CALL_PROVIDERS.WHATSAPP
);

// Speaker + camera (LiveKit calls). Speaker toggle only where the browser supports
// output-device selection; video only on internal (agent<->agent) calls.
const isSpeakerOn = ref(false);
const isCameraOn = ref(false);
const isLivekitActive = computed(
  () => activeCall.value?.provider === VOICE_CALL_PROVIDERS.LIVEKIT
);
// Show the speaker button on any LiveKit call. Where the browser doesn't support output-
// device selection (iOS Safari), toggling is a no-op but the button still shows for UX.
const showSpeaker = computed(() => isLivekitActive.value);
// Video (camera) available on internal (agent<->agent) LiveKit calls only.
const showVideo = computed(
  () => isLivekitActive.value && activeCall.value?.callKind === 'internal'
);
// Render the tiles when the OTHER side publishes camera video (even if our own camera is
// off). Driven by the components-core-backed useTracks composable instead of the retired
// 'video:track' CustomEvent.
const { remoteTracks: remoteCameraTracks } = useTracks(
  liveKitRoomRef,
  [Track.Source.Camera],
  { onlySubscribed: false }
);
const hasRemoteVideo = computed(() => remoteCameraTracks.value.length > 0);

// Speaker output via the components-core-backed composable (replaces the hand-rolled
// getDevices/switchDevice on LiveKitVoiceClient — first Option B migration).
const { devices: audioOutputs, setActiveDevice: setAudioOutput } = useMediaDevices(
  'audiooutput',
  liveKitRoomRef
);
const toggleSpeaker = async () => {
  if (!isLivekitActive.value || !audioOutputs.value.length) return;
  // Cycle to the next output device (e.g. earpiece <-> speaker/headphones).
  const next = audioOutputs.value[isSpeakerOn.value ? 0 : audioOutputs.value.length - 1];
  await setAudioOutput(next.deviceId);
  isSpeakerOn.value = !isSpeakerOn.value;
};

const toggleCamera = async () => {
  if (!isLivekitActive.value) return;
  const next = !isCameraOn.value;
  try {
    // setCameraEnabled requests camera permission first (Google-Meet style); only flip
    // the UI state once it actually succeeds, so a denied prompt doesn't desync the button.
    await LiveKitVoiceClient.setCameraEnabled(next);
    isCameraOn.value = next;
  } catch (e) {
    isCameraOn.value = false;
    useAlert('Camera permission is needed to turn on video.');
  }
};

const primaryIncomingCall = computed(() =>
  hasActiveCall.value ? null : incomingCalls.value[0] || null
);

const stackedIncomingCalls = computed(() =>
  hasActiveCall.value ? incomingCalls.value : incomingCalls.value.slice(1)
);

const mainCardState = computed(() => {
  if (hasActiveCall.value) return VOICE_CALL_DIRECTION.ONGOING;
  const direction = primaryIncomingCall.value?.callDirection;
  return direction === VOICE_CALL_DIRECTION.OUTBOUND
    ? VOICE_CALL_DIRECTION.OUTGOING
    : VOICE_CALL_DIRECTION.INCOMING;
});

// Stacked cards are always non-active (ringing) calls, so reflect each call's
// real direction. An outbound call must render as OUTGOING — otherwise it shows
// the incoming-only dismiss (✕) control and the agent could drop it locally
// without terminating, leaving the customer ringing with no widget to end it.
const stackedCardState = call =>
  call?.callDirection === VOICE_CALL_DIRECTION.OUTBOUND
    ? VOICE_CALL_DIRECTION.OUTGOING
    : VOICE_CALL_DIRECTION.INCOMING;

const toggleMute = () => {
  isMuted.value = !isMuted.value;
  if (isWhatsappActive.value) {
    setWhatsappCallMuted(isMuted.value);
  } else if (activeCall.value?.provider === VOICE_CALL_PROVIDERS.LIVEKIT) {
    LiveKitVoiceClient.setMuted(isMuted.value);
  } else {
    TwilioVoiceClient.setMuted(isMuted.value);
  }
};

watch(hasActiveCall, active => {
  if (!active) {
    isMuted.value = false;
    isSpeakerOn.value = false;
    isCameraOn.value = false;
  }
});

// Convert ISO 3166-1 alpha-2 country code (e.g. "US") to its regional indicator
// flag emoji. Returns empty string if the code is missing or malformed.
const countryCodeToFlag = code => {
  if (!code || code.length !== 2) return '';
  const base = 0x1f1e6;
  const offset = 'A'.charCodeAt(0);
  return String.fromCodePoint(
    ...code
      .toUpperCase()
      .split('')
      .map(c => base + (c.charCodeAt(0) - offset))
  );
};

const getCallInfo = call => {
  // Internal (agent<->agent) calls have no conversation/inbox — show the colleague's
  // name + an "Internal call" label instead of the customer-support fallbacks.
  if (call?.callKind === 'internal') {
    return {
      conversation: null,
      inbox: null,
      contactName: call?.caller?.name || 'Colleague',
      phoneNumber: '',
      inboxName: 'Internal call',
      location: 'Internal call',
      countryFlag: '',
      hasLocation: false,
      avatar: call?.caller?.avatar,
    };
  }
  const conversation = store.getters.getConversationById(call?.conversationId);
  // Look up inbox from the call's own inboxId — the conversation can drop out
  // of the Vuex store when the user navigates between inbox views, so going
  // through `conversation.inbox_id` would lose the inbox name (and fall back
  // to the literal "Customer support" string).
  const inbox = store.getters['inboxes/getInbox'](call?.inboxId);
  const sender = conversation?.meta?.sender;
  // `caller` is the snapshot captured when the call first landed (from the
  // message sender or the WhatsApp cable payload). It outlives the
  // conversation being in the store, so prefer it for display.
  const caller = call?.caller;
  const additional =
    sender?.additional_attributes || caller?.additionalAttributes || {};
  const city = additional.city || '';
  const countryCode = additional.country_code || '';
  const country =
    additional.country ||
    countriesList.find(c => c.id === countryCode.toUpperCase())?.name ||
    '';
  // Prefer the richest available location string ("City, Country"); fall back to
  // whichever single field is present; finally fall back to the inbox name so
  // there's always something to show.
  const locationParts = [city, country].filter(Boolean);
  const location =
    locationParts.join(', ') || inbox?.name || 'Customer support';
  return {
    conversation,
    inbox,
    contactName:
      caller?.name ||
      sender?.name ||
      caller?.phone ||
      sender?.phone_number ||
      'Unknown caller',
    phoneNumber: caller?.phone || sender?.phone_number || '',
    inboxName: inbox?.name || 'Customer support',
    location,
    countryFlag: countryCodeToFlag(countryCode),
    hasLocation: locationParts.length > 0,
    avatar: caller?.avatar || sender?.avatar || sender?.thumbnail,
  };
};

const goToConversation = call => {
  const conversationId = call?.conversationId;
  const accountId = route.params.accountId;
  if (!conversationId || !accountId) return;
  router.push({
    path: frontendURL(conversationUrl({ accountId, id: conversationId })),
  });
};

const handleEndCall = async () => {
  const call = activeCall.value;
  if (!call) return;

  // Internal (agent<->agent) calls have no inbox/conversation — end via the internal
  // endpoint + tear down the LiveKit room directly.
  if (call.callKind === 'internal') {
    try {
      LiveKitVoiceClient.endClientCall();
      if (call.callId) await VoiceAPI.endInternalCall(call.callId);
    } finally {
      useCallsStore().removeCall(call.callSid);
    }
    return;
  }

  const inboxId = call.inboxId || getCallInfo(call).conversation?.inbox_id;
  if (!inboxId) return;

  await endCallSession({
    conversationId: call.conversationId,
    inboxId,
    callSid: call.callSid,
  });
};

const handleJoinCall = async call => {
  if (!call || isJoining.value) return;
  const { conversation } = getCallInfo(call);

  if (hasActiveCall.value) {
    await handleEndCall();
  }

  // The conversation may not be hydrated yet (post-refresh seeding path);
  // call.inboxId already carries what joinCall needs.
  const result = await joinCall({
    conversationId: call.conversationId,
    inboxId: call.inboxId || conversation?.inbox_id,
    callSid: call.callSid,
  });

  if (result && conversation) {
    router.push({
      name: 'inbox_conversation',
      params: { conversation_id: call.conversationId },
    });
  }
};

// Auto-join outbound calls when window is visible. WhatsApp outbound has no
// separate join step (the offer was sent at initiate time and the answer is
// applied directly by the cable handler), so this only covers Twilio.
watch(
  () => incomingCalls.value[0],
  call => {
    if (
      call?.callDirection === VOICE_CALL_DIRECTION.OUTBOUND &&
      call?.provider !== VOICE_CALL_PROVIDERS.WHATSAPP &&
      !hasActiveCall.value &&
      WindowVisibilityHelper.isWindowVisible()
    ) {
      handleJoinCall(call);
    }
  },
  { immediate: true }
);

// Loop the ringtone while an inbound call is unanswered. Stop the moment any
// call is active (we joined), every inbound call cleared, or the widget tears
// down. The watcher only fires on the boolean transitioning, so additional
// ringing calls arriving while one is already ringing don't restart the audio
// — they silently stack into the UI without producing a fresh ring.
// Browser autoplay may reject the first play() if the tab has no prior
// user gesture; that's fine — the visual widget still surfaces the call.
const ringtone = new Audio(RINGTONE_URL);
ringtone.loop = true;
ringtone.volume = 1;

// Mobile/desktop browsers block audio.play() without a prior user gesture, so an
// incoming-call ringtone would be silently rejected (esp. on phones). Prime the audio
// element on the FIRST user interaction anywhere (play muted then pause) — after that
// the browser allows the ringtone to autoplay when a call arrives.
let ringtoneUnlocked = false;
const unlockRingtone = () => {
  if (ringtoneUnlocked) return;
  ringtoneUnlocked = true;
  const prev = ringtone.muted;
  ringtone.muted = true;
  ringtone
    .play()
    .then(() => {
      ringtone.pause();
      ringtone.currentTime = 0;
      ringtone.muted = prev;
    })
    .catch(() => {
      ringtone.muted = prev;
    });
  window.removeEventListener('pointerdown', unlockRingtone);
  window.removeEventListener('keydown', unlockRingtone);
};
window.addEventListener('pointerdown', unlockRingtone);
window.addEventListener('keydown', unlockRingtone);

const stopRingtone = () => {
  ringtone.pause();
  ringtone.currentTime = 0;
};

const ringingInbound = computed(() =>
  incomingCalls.value.some(
    call => call.callDirection !== VOICE_CALL_DIRECTION.OUTBOUND
  )
);

watch(
  () => ringingInbound.value && !hasActiveCall.value,
  shouldRing => {
    if (shouldRing) {
      ringtone.play().catch(() => {});
      // Mobile browsers often block the ringtone audio (autoplay policy). Vibrate as a
      // fallback so the phone still signals an incoming call, repeating while ringing.
      startVibrate();
    } else {
      stopRingtone();
      stopVibrate();
    }
  },
  { immediate: true }
);

// Caller-side RINGBACK: LiveKit does not play a ringback tone, so the outbound caller
// hears silence while waiting for the callee to answer. Play the ringtone as a ringback
// from the moment the caller's outbound call is active until the callee joins (the
// 'call:answered' event fired by LiveKitVoiceClient when the peer connects).
const ringback = new Audio(RINGTONE_URL);
ringback.loop = true;
ringback.volume = 0.5;
// True once the callee has joined (the 'call:answered' event), so the ringback stops.
const remoteParticipantPresent = ref(false);
const isOutboundRinging = computed(
  () =>
    isLivekitActive.value &&
    activeCall.value?.callDirection === VOICE_CALL_DIRECTION.OUTBOUND &&
    !remoteParticipantPresent.value
);
watch(isOutboundRinging, ringing => {
  if (ringing) {
    ringback.play().catch(() => {});
  } else {
    ringback.pause();
    ringback.currentTime = 0;
  }
});
const onCallAnswered = () => {
  remoteParticipantPresent.value = true;
};
// LiveKitVoiceClient fires 'call:answered' when the callee joins the room — stop the ringback.
LiveKitVoiceClient.addEventListener('call:answered', onCallAnswered);
onBeforeUnmount(() =>
  LiveKitVoiceClient.removeEventListener('call:answered', onCallAnswered)
);
// Reset the answered flag whenever the active call clears, so the next outbound call rings.
watch(hasActiveCall, active => {
  if (!active) remoteParticipantPresent.value = false;
});

let vibrateTimer = null;
const startVibrate = () => {
  if (!navigator.vibrate || vibrateTimer) return;
  const pulse = () => navigator.vibrate([600, 400]);
  pulse();
  vibrateTimer = setInterval(pulse, 1500);
};
const stopVibrate = () => {
  if (vibrateTimer) {
    clearInterval(vibrateTimer);
    vibrateTimer = null;
  }
  navigator.vibrate?.(0);
};

onBeforeUnmount(() => {
  stopRingtone();
  stopVibrate();
});
</script>

<template>
  <div
    v-if="incomingCalls.length || hasActiveCall"
    class="fixed ltr:right-4 rtl:left-4 bottom-4 z-50 flex flex-col gap-3 w-[calc(100vw-2rem)] sm:w-[400px] max-w-[400px]"
  >
    <!-- Stacked incoming calls (shown above the primary card) -->
    <CallCard
      v-for="call in stackedIncomingCalls"
      :key="call.callSid"
      :call="call"
      :state="stackedCardState(call)"
      :call-info="getCallInfo(call)"
      @accept="handleJoinCall(call)"
      @reject="rejectIncomingCall(call.callSid)"
      @dismiss="dismissCall(call.callSid)"
      @go-to-conversation="goToConversation(call)"
    />

    <!-- Main Call Widget -->
    <!-- Video tiles (internal call, camera on) -->
    <CallVideoTiles v-if="hasActiveCall && showVideo && (isCameraOn || hasRemoteVideo)" />

    <CallCard
      v-if="hasActiveCall || primaryIncomingCall"
      :call="activeCall || primaryIncomingCall"
      :state="mainCardState"
      :call-info="getCallInfo(activeCall || primaryIncomingCall)"
      :duration="hasActiveCall ? formattedCallDuration : ''"
      :is-muted="isMuted"
      :show-mute="hasActiveCall"
      :show-speaker="showSpeaker"
      :is-speaker-on="isSpeakerOn"
      :show-video="showVideo"
      :is-camera-on="isCameraOn"
      @accept="handleJoinCall(primaryIncomingCall)"
      @reject="rejectIncomingCall(primaryIncomingCall?.callSid)"
      @dismiss="dismissCall(primaryIncomingCall?.callSid)"
      @end="handleEndCall"
      @toggle-mute="toggleMute"
      @toggle-speaker="toggleSpeaker"
      @toggle-camera="toggleCamera"
      @go-to-conversation="goToConversation(activeCall || primaryIncomingCall)"
    />
  </div>
</template>
