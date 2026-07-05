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
  rescue Voice::InternalCallBuilder::CalleeBusyError
    # The colleague is already on a call — tell the caller instead of double-ringing them.
    render json: { status: 'busy', message: "#{callee.name} is already on a call" }, status: :conflict
  end

  # GET /api/v1/accounts/:account_id/internal_calls/active
  # Session rehydrate: the current user's in-progress internal call (if any), so the
  # browser can rejoin the LiveKit room after a page refresh. Returns null if none.
  def active
    call = Current.account.calls
                  .where(call_kind: 'internal', status: %i[ringing in_progress])
                  .where('accepted_by_agent_id = :id OR callee_user_id = :id', id: Current.user.id)
                  .order(created_at: :desc).first
    return render(json: { active: nil }) unless call

    # caller_user is aliased onto accepted_by_agent_id (see Call model) — compare via the
    # association's id, not a non-existent caller_user_id column.
    is_caller = call.accepted_by_agent_id == Current.user.id
    render json: {
      active: {
        id: call.id, room_name: call.meta['room_name'], status: call.status,
        direction: is_caller ? 'outbound' : 'inbound',
        peer: (is_caller ? call.callee_user : call.caller_user)&.name,
        token: mint_token(call.meta['room_name']),
      },
    }
  end

  # GET /api/v1/accounts/:account_id/internal_calls/:id/token
  # Either party fetches a LiveKit token for the internal room to join it.
  def token
    call = internal_call!
    # A party fetching a token means they're joining → the call is now in progress. This
    # lets the rehydrate endpoint know an active call exists to rejoin after a refresh.
    call.update!(status: :in_progress) if call.status == 'ringing'
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
      'internal_call.ended',
      { account_id: Current.account.id, callSid: call.meta['room_name'], callId: call.id }
    )
    render json: { status: 'success', id: call.id }
  end

  private

  # Per-user session scoping: a user may only act on a call they are a PARTY to (caller or
  # callee). This prevents fetching a token for — or ending — another user's call. Features
  # are enabled only through the acting user's own session (Current.user).
  def internal_call!
    Current.account.calls
           .where(call_kind: 'internal')
           .where('accepted_by_agent_id = :id OR callee_user_id = :id', id: Current.user.id)
           .find(params[:id])
  end

  def mint_token(room_name)
    Voice::Provider::Livekit::TokenService.new(
      user: Current.user, account: Current.account, room_name: room_name
    ).generate
  end
end
