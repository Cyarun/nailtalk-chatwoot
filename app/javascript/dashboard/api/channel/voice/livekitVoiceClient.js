import {
  Room,
  RoomEvent,
  Track,
  supportsAudioOutputSelection,
} from "livekit-client";
import { ref } from "vue";
import VoiceAPI from "dashboard/api/channel/voice/voiceAPIClient";

const createCallDisconnectedEvent = () => new CustomEvent("call:disconnected");

// Reactive handle on the current LiveKit Room, so Vue composables (useMediaDevices,
// useTracks, useLocalMedia, ...) built on @livekit/components-core can react to
// connect/disconnect. The client sets it; composables read it.
export const liveKitRoomRef = ref(null);

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
  // Request mic permission UP FRONT (in the answer/call click gesture) BEFORE connecting.
  // If we let LiveKit prompt for the mic mid-connect (setMicrophoneEnabled after connect),
  // the permission dialog races/interrupts the WebRTC handshake and the call aborts as a
  // client-initiated disconnect — especially on mobile. Prompting first (and reusing the
  // granted stream) avoids that entirely.
  async ensureMicPermission() {
    if (!navigator.mediaDevices?.getUserMedia) return;
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    // We only needed the permission grant + to warm the device; stop the temp track so
    // LiveKit acquires its own (the OS keeps the permission granted for the session).
    stream.getTracks().forEach(t => t.stop());
  }

  async joinClientCall() {
    if (!this.token || !this.url) {
      throw new Error("LiveKit token not initialized");
    }
    // Guard against a concurrent second join for the same room (a double-invoke would
    // disconnect the first attempt as "client initiated" and break the call).
    if (this._joining) return this._joining;
    this._joining = this._doJoin().finally(() => {
      this._joining = null;
    });
    return this._joining;
  }

  async _doJoin() {
    // Ask for the mic BEFORE connecting (in the user gesture) — see ensureMicPermission.
    await this.ensureMicPermission();
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
    this.room = new Room({
      adaptiveStream: true,
      dynacast: true,
      // Pin call-quality defaults so a browser/SDK change can't silently regress them.
      // echo/noise/AGC are browser hints (usually on by default); pinning makes them
      // explicit. DTX (silence suppression) + RED (packet-loss resilience) protect
      // intelligibility on mobile/lossy networks. All verified in the LiveKit docs.
      audioCaptureDefaults: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
      publishDefaults: {
        dtx: true,
        red: true,
      },
    });
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
    const roomRef = this.room;
    this.room.on(RoomEvent.Disconnected, (reason) => {
      // eslint-disable-next-line no-console
      console.info('LiveKit room disconnected', reason);
      // However the call ends (agent hangs up, the OTHER side hangs up, network drop),
      // release the mic/camera so the browser tab's device indicator turns off. Operate
      // on the captured room ref and never let cleanup throw into the SDK.
      try {
        this._stopLocalTracks(roomRef);
      } catch (e) {
        // best-effort
      }
      this._cleanupAudio();
      // Only clear this.room if it's still THIS room (don't clobber a newer call).
      if (this.room === roomRef) this.room = null;
      if (liveKitRoomRef.value === roomRef) liveKitRoomRef.value = null;
      this.dispatchEvent(createCallDisconnectedEvent());
    });

    await this.room.connect(this.url, this.token);
    liveKitRoomRef.value = this.room; // expose to Vue composables
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

  // Remote participants' already-subscribed video tracks — so a video-tile component that
  // mounts AFTER the remote track arrived can still attach it (the 'video:track' event may
  // have fired before the component's listener existed).
  getRemoteVideoTracks() {
    const tracks = [];
    const participants = this.room?.remoteParticipants;
    if (!participants) return tracks;
    participants.forEach(p => {
      // A publication with a videoTrack is a video track (per LiveKit's documented
      // getTrackPublication(...).videoTrack pattern) — don't rely on pub.kind.
      p.trackPublications?.forEach(pub => {
        if (pub.videoTrack) tracks.push(pub.videoTrack);
      });
    });
    return tracks;
  }

  // Our own published camera track (for the self-view tile), if the camera is on.
  getLocalVideoTrack() {
    const pub = this.room?.localParticipant?.getTrackPublication?.(
      Track.Source.Camera
    );
    return pub?.videoTrack || null;
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
      liveKitRoomRef.value = null;
    }
    this._cleanupAudio();
    this.token = null;
    this.url = null;
    this.dispatchEvent(createCallDisconnectedEvent());
  }

  _stopLocalTracks(room = this.room) {
    const lp = room?.localParticipant;
    if (!lp) return;
    try {
      // Copy first — unpublishing while iterating the live map can throw.
      const pubs = Array.from(lp.trackPublications?.values?.() || []);
      pubs.forEach(pub => {
        try {
          pub.track?.stop(); // releases the underlying MediaStreamTrack (frees the device)
        } catch (e) {
          // ignore per-track
        }
      });
    } catch (e) {
      // best-effort — disconnect(true) is the backstop.
    }
  }
}

export default new LiveKitVoiceClient();
