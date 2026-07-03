import { Room, RoomEvent } from "livekit-client";
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

  // Join the caller's room + publish the mic (this is "answering" the call).
  async joinClientCall() {
    if (!this.token || !this.url) {
      throw new Error("LiveKit token not initialized");
    }
    this.room = new Room({ adaptiveStream: true, dynacast: true });
    this.room.on(RoomEvent.Disconnected, () => {
      this.dispatchEvent(createCallDisconnectedEvent());
    });
    await this.room.connect(this.url, this.token);
    await this.room.localParticipant.setMicrophoneEnabled(true);
    return this.room;
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
    this.token = null;
    this.url = null;
    this.dispatchEvent(createCallDisconnectedEvent());
  }
}

export default new LiveKitVoiceClient();
