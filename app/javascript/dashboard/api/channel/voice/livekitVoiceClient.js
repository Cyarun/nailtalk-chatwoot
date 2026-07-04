import {
  Room,
  RoomEvent,
  Track,
  supportsAudioOutputSelection,
} from "livekit-client";
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
    this.room.on(RoomEvent.TrackSubscribed, (track, publication, participant) => {
      if (track.kind === Track.Kind.Audio) {
        const el = track.attach();
        el.autoplay = true;
        el.setAttribute('data-livekit-audio', 'true');
        document.body.appendChild(el);
        this._audioElements.push(el);
      } else if (track.kind === Track.Kind.Video) {
        // Remote video (internal video call) — emit so the UI mounts a tile.
        this.dispatchEvent(
          new CustomEvent('video:track', {
            detail: { track, participant: participant?.identity, remote: true },
          })
        );
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
      // However the call ends (agent hangs up, the OTHER side hangs up, network drop),
      // release the mic/camera so the browser tab's device indicator turns off.
      this._stopLocalTracks();
      this._cleanupAudio();
      this.room = null;
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

  // --- Device selection (mic / speaker / camera) ---
  // List devices of a kind: 'audioinput' | 'audiooutput' | 'videoinput'.
  // eslint-disable-next-line class-methods-use-this
  async getDevices(kind) {
    try {
      return await Room.getLocalDevices(kind);
    } catch (e) {
      return [];
    }
  }

  // Switch the active mic/speaker/camera to a chosen device (e.g. headphones).
  async switchDevice(kind, deviceId) {
    if (this.room && deviceId) {
      await this.room.switchActiveDevice(kind, deviceId);
    }
  }

  // Speaker toggle is only meaningful where the browser supports output selection
  // (desktop + Android Chrome). iOS Safari controls the speaker at the OS level.
  // eslint-disable-next-line class-methods-use-this
  supportsSpeakerSelection() {
    return supportsAudioOutputSelection();
  }

  // --- Video (internal calls only) ---
  async setCameraEnabled(enabled) {
    if (!this.room?.localParticipant) return;
    await this.room.localParticipant.setCameraEnabled(enabled);
    if (enabled) {
      // Emit the local camera track so the UI can show a self-view tile.
      const pub = this.room.localParticipant.getTrackPublication(
        Track.Source.Camera
      );
      if (pub?.videoTrack) {
        this.dispatchEvent(
          new CustomEvent('video:track', {
            detail: { track: pub.videoTrack, remote: false },
          })
        );
      }
    }
  }

  isCameraEnabled() {
    return !!this.room?.localParticipant?.isCameraEnabled;
  }

  endClientCall() {
    if (this.room) {
      // Explicitly STOP every local track first so the mic/camera hardware is really
      // released (the browser tab's mic/camera indicator goes off). room.disconnect()
      // defaults to stopTracks:true, but we stop them ourselves too so a track that
      // wasn't fully tracked can't leave getUserMedia running.
      this._stopLocalTracks();
      this.room.disconnect(true); // true = stop local tracks
      this.room = null;
    }
    this._cleanupAudio();
    this.token = null;
    this.url = null;
    this.dispatchEvent(createCallDisconnectedEvent());
  }

  _stopLocalTracks() {
    const lp = this.room?.localParticipant;
    if (!lp) return;
    try {
      lp.trackPublications.forEach(pub => {
        // stop() releases the underlying MediaStreamTrack (frees the device).
        pub.track?.stop();
        if (pub.track) lp.unpublishTrack(pub.track).catch(() => {});
      });
    } catch (e) {
      // best-effort — disconnect(true) is the backstop.
    }
  }
}

export default new LiveKitVoiceClient();
