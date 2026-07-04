# frozen_string_literal: true

# Add a direct recording_url string column so a LiveKit call can store a public MinIO
# recording URL directly (instead of relying on an ActiveStorage attachment). The model
# prefers this column and falls back to the ActiveStorage blob URL (Twilio path).
class AddRecordingUrlToCalls < ActiveRecord::Migration[7.1]
  def change
    add_column :calls, :recording_url, :string
  end
end
