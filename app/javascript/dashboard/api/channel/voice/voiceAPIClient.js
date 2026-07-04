/* global axios */
import ApiClient from '../../ApiClient';
import ContactsAPI from '../../contacts';

class VoiceAPI extends ApiClient {
  constructor() {
    super('voice', { accountScoped: true });
  }

  // eslint-disable-next-line class-methods-use-this
  initiateCall(contactId, inboxId) {
    return ContactsAPI.initiateCall(contactId, inboxId).then(r => r.data);
  }

  leaveConference({ inboxId, conversationId, callSid }) {
    return axios
      .delete(`${this.baseUrl()}/inboxes/${inboxId}/conference`, {
        params: { conversation_id: conversationId, call_sid: callSid },
      })
      .then(r => r.data);
  }

  joinConference({ conversationId, inboxId, callSid }) {
    return axios
      .post(`${this.baseUrl()}/inboxes/${inboxId}/conference`, {
        conversation_id: conversationId,
        call_sid: callSid,
      })
      .then(r => r.data);
  }

  getToken(inboxId) {
    if (!inboxId) return Promise.reject(new Error('Inbox ID is required'));
    return axios
      .get(`${this.baseUrl()}/inboxes/${inboxId}/conference/token`)
      .then(r => r.data);
  }

  // Internal (agent<->agent) calls — no inbox, over a LiveKit room.
  initiateInternalCall(calleeUserId) {
    return axios
      .post(`${this.baseUrl()}/internal_calls`, { callee_user_id: calleeUserId })
      .then(r => r.data);
  }

  getInternalCallToken(callId) {
    return axios
      .get(`${this.baseUrl()}/internal_calls/${callId}/token`)
      .then(r => r.data);
  }

  endInternalCall(callId) {
    return axios
      .delete(`${this.baseUrl()}/internal_calls/${callId}`)
      .then(r => r.data);
  }
}

export default new VoiceAPI();
