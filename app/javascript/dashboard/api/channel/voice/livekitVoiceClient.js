import { Room, RoomEvent, Track } from "livekit-client";
import VoiceAPI from "dashboard/api/channel/voice/voiceAPIClient";

const createCallDisconnectedEvent = () => new CustomEvent("call:disconnected");

// LiveKitVoiceClient — mirrors TwilioVoiceClient's public surface so useCallSession can
// drive it the same way, but joins a LiveKit Room (WebRTC) instead of a Twilio Device.
// Human-first: the agent connects to the caller's LiveKit room and publishes their mic.
class LiveKitVoiceClient extends EventTarget {
  constructor() {
    super();
    this.room = null;
    this.token = null;
    this.url = null;
  }

  // Fetch a LiveKit join token for the ringing call in this inbox.
  async initializeDevice(inboxId) {
    const data = await VoiceAPI.getToken(inboxId);
    this.token = data.token;
    this.url = data.livekit_url;
    this.roomName = data.room_name;
    return data;
  }

  // Fetch a token for an internal (agent<->agent) call room (no inbox).
  async initializeInternalDevice(callId) {
    const data = await VoiceAPI.getInternalCallToken(callId);
    this.token = data.token;
    this.url = data.livekit_url;
    this.roomName = data.room_name;
    return data;
  }

  // Join the caller's room + publish the mic (this is "answering" the call).
  async joinClientCall() {
    if (!this.token || !this.url) {
      throw new Error("LiveKit token not initialized");
    }
    // Never leave a previous room connected — disconnect it first so we never leak a
    // silent background call (no duplicate/zombie connections).
    if (this.room) {
      try {
        await this.room.disconnect();
      } catch (e) {
        // ignore — we are replacing it anyway
      }
      this.room = null;
    }
    this.room = new Room({ adaptiveStream: true, dynacast: true });
    this._audioElements = [];

    // CRITICAL: play the OTHER participant's audio. Subscribing to a track only makes it
    // available — LiveKit does NOT auto-play it. We must attach() it to a DOM element,
    // else neither side hears the other (per LiveKit client-sdk-js docs).
    this.room.on(RoomEvent.TrackSubscribed, (track) => {
      if (track.kind === Track.Kind.Audio) {
        const el = track.attach();
        el.autoplay = true;
        el.setAttribute('data-livekit-audio', 'true');
        document.body.appendChild(el);
        this._audioElements.push(el);
      }
    });
    this.room.on(RoomEvent.TrackUnsubscribed, (track) => {
      track.detach().forEach(el => el.remove());
    });
    // Browser autoplay policy can block playback; startAudio() unlocks it. Safe to call
    // here because join happens inside the user's click (answer / call).
    this.room.on(RoomEvent.AudioPlaybackStatusChanged, () => {
      if (!this.room?.canPlaybackAudio) {
        this.room.startAudio().catch(() => {});
      }
    });
    this.room.on(RoomEvent.Disconnected, (reason) => {
      // eslint-disable-next-line no-console
      console.info('LiveKit room disconnected', reason);
      this._cleanupAudio();
      this.dispatchEvent(createCallDisconnectedEvent());
    });

    await this.room.connect(this.url, this.token);
    await this.room.localParticipant.setMicrophoneEnabled(true);
    // Unlock playback within the user gesture (mobile Safari/Chrome autoplay).
    if (!this.room.canPlaybackAudio) {
      await this.room.startAudio().catch(() => {});
    }
    return this.room;
  }

  _cleanupAudio() {
    (this._audioElements || []).forEach(el => el.remove());
    this._audioElements = [];
  }

  setMuted(shouldMute) {
    if (this.room?.localParticipant) {
      this.room.localParticipant.setMicrophoneEnabled(!shouldMute);
    }
  }

  endClientCall() {
    if (this.room) {
      this.room.disconnect();
      this.room = null;
    }
    this._cleanupAudio();
    this.token = null;
    this.url = null;
    this.dispatchEvent(createCallDisconnectedEvent());
  }
}

export default new LiveKitVoiceClient();
