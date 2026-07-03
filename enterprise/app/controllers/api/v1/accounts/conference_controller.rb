class Api::V1::Accounts::ConferenceController < Api::V1::Accounts::BaseController
  before_action :set_voice_inbox_for_conference
  rescue_from CustomExceptions::CallAlreadyAccepted, with: :render_call_already_accepted

  def token
    if livekit_inbox?
      call = latest_ringing_livekit_call
      render json: Voice::Provider::Livekit::TokenService.new(
        inbox: @voice_inbox, user: Current.user, account: Current.account,
        room_name: call&.meta&.dig(%q{room_name})
      ).generate
    else
      render json: Voice::Provider::Twilio::TokenService.new(
        inbox: @voice_inbox, user: Current.user, account: Current.account
      ).generate
    end
  end

  def create
    call = resolve_call!

    conference_service = Voice::Provider::Twilio::ConferenceService.new(call: call)
    conference_sid = conference_service.ensure_conference_sid
    conference_service.mark_agent_joined(user: current_user)

    render json: {
      status: 'success',
      id: call.conversation.display_id,
      conference_sid: conference_sid,
      using_webrtc: true
    }
  end

  def destroy
    call = resolve_call!
    rejecting = agent_rejecting_before_pickup?(call)
    # Tear down provider side first so a teardown failure leaves the call repairable.
    if call.livekit?
      call.update!(status: :completed) unless Call::TERMINAL_STATUSES.include?(call.status)
    else
      Voice::Provider::Twilio::ConferenceService.new(call: call).end_conference
    end
    finalize_as_agent_reject!(call) if rejecting
    render json: { status: 'success', id: call.conversation.display_id }
  end

  private

  def resolve_call!
    sid = params[:call_sid].presence
    raise ActionController::ParameterMissing, :call_sid if sid.blank?

    conversation = fetch_conversation_by_display_id
    Call.where(inbox_id: @voice_inbox.id, provider: call_provider, conversation_id: conversation.id)
        .find_by!(provider_call_id: sid)
  end

  def livekit_inbox?
    @voice_inbox.channel.respond_to?(:livekit_voice?) && @voice_inbox.channel.livekit_voice?
  end

  def call_provider
    livekit_inbox? ? :livekit : :twilio
  end

  def latest_ringing_livekit_call
    Call.where(inbox_id: @voice_inbox.id, provider: :livekit, status: %w[ringing in_progress])
        .order(:created_at).last
  end

  def set_voice_inbox_for_conference
    @voice_inbox = Current.account.inboxes.find(params[:inbox_id])
    authorize @voice_inbox, :show?
  end

  def fetch_conversation_by_display_id
    cid = params[:conversation_id]
    raise ActiveRecord::RecordNotFound, 'conversation_id required' if cid.blank?

    conversation = @voice_inbox.conversations.find_by!(display_id: cid)
    authorize conversation, :show?
    conversation
  end

  def render_call_already_accepted(error)
    render json: { error: error.message }, status: :conflict
  end

  # A hangup before pickup is treated as an agent rejection, matching WhatsApp.
  def agent_rejecting_before_pickup?(call)
    call.ringing? && call.accepted_by_agent_id.nil?
  end

  def finalize_as_agent_reject!(call)
    # Re-check under a row lock: a webhook may have accepted/completed the call
    # while end_conference was in flight, so don't force agent_rejected on stale state.
    rejected = call.with_lock do
      next false unless agent_rejecting_before_pickup?(call)

      call.update!(status: 'failed', end_reason: 'agent_rejected', accepted_by_agent_id: Current.user.id)
      true
    end
    Voice::CallMessageBuilder.new(call).update_status!(status: 'failed', agent: Current.user) if rejected
  end
end
