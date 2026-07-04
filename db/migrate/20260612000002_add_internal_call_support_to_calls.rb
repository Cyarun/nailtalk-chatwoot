# frozen_string_literal: true

# Internal calling (agent<->agent, AI<->agent) reuses the Call model. Internal calls have
# no inbox/conversation/contact (they are user-to-user over a LiveKit room, no PSTN), so
# make those nullable, and add callee_user_id + call_kind to distinguish internal vs pstn.
class AddInternalCallSupportToCalls < ActiveRecord::Migration[7.1]
  def change
    change_column_null :calls, :inbox_id, true
    change_column_null :calls, :conversation_id, true
    change_column_null :calls, :contact_id, true
    add_column :calls, :callee_user_id, :bigint
    add_column :calls, :call_kind, :string, default: "pstn", null: false
    add_index :calls, :callee_user_id
    add_index :calls, :call_kind
  end
end
