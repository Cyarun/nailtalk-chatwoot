class Api::V1::Accounts::InternalCallsController < Api::V1::Accounts::BaseController
  # Internal (agent<->agent, AI<->agent) calls over a LiveKit room — NO PSTN, NO Vobiz,
  # NO inbox. The caller initiates (rings the callee), both fetch a token for the shared
  # room and join in the browser via LiveKitVoiceClient.

  # POST /api/v1/accounts/:account_id/internal_calls
  # Caller initiates: create the internal Call + ring the callee.
  def create
    callee = Current.account.users.find(params[:callee_user_id])
    call = Voice::InternalCallBuilder.new(
      account: Current.account, caller_user: Current.user, callee_user: callee
    ).perform!
    render json: {
      status: 'success', id: call.id, room_name: call.meta['room_name'],
      token: mint_token(call.meta['room_name'])
    }
  end

  # GET /api/v1/accounts/:account_id/internal_calls/:id/token
  # Either party fetches a LiveKit token for the internal room to join it.
  def token
    call = internal_call!
    render json: mint_token(call.meta['room_name']).merge(room_name: call.meta['room_name'])
  end

  # DELETE /api/v1/accounts/:account_id/internal_calls/:id
  # End the internal call (either party hangs up).
  def destroy
    call = internal_call!
    unless Call::TERMINAL_STATUSES.include?(call.status)
      call.update!(status: :completed)
    end
    ActionCableBroadcastJob.perform_later(
      [call.caller_user&.pubsub_token, call.callee_user&.pubsub_token].compact,
      'internal_call.ended', { callSid: call.meta['room_name'], callId: call.id }
    )
    render json: { status: 'success', id: call.id }
  end

  private

  def internal_call!
    Current.account.calls.where(call_kind: 'internal').find(params[:id])
  end

  def mint_token(room_name)
    Voice::Provider::Livekit::TokenService.new(
      user: Current.user, account: Current.account, room_name: room_name
    ).generate
  end
end
