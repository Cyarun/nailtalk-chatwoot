# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/api/media/

class Whatsapp::IncomingMessageWhatsappCloudService < Whatsapp::IncomingMessageBaseService
  # Meta's media CDN (lookaside.fbsbx.com) rejects requests with a missing/bot-like
  # User-Agent (400/connection reset), and the container -> CDN path is flaky on the VPS
  # (IPv6/NAT/Docker bridge -> Down::ConnectionError "connection reset by peer"). We send a
  # fixed UA and retry with backoff. Ref: chatwoot/chatwoot#13612, #9809.
  MEDIA_USER_AGENT = 'curl/7.64.1'.freeze
  MEDIA_DOWNLOAD_RETRIES = 3

  private

  def processed_params
    @processed_params ||= params[:entry].try(:first).try(:[], 'changes').try(:first).try(:[], 'value')
  end

  def download_attachment_file(attachment_payload)
    media_id = attachment_payload[:id]
    url_response = HTTParty.get(
      inbox.channel.media_url(media_id),
      headers: media_lookup_headers
    )

    # This url response will be failure if the access token has expired.
    inbox.channel.authorization_error! if url_response.unauthorized?

    unless url_response.success?
      # Previously this returned silently, so a broken media pipeline was invisible.
      # WARN with the real status/body so the failing step is diagnosable (nt-97uh).
      Rails.logger.warn(
        "[whatsapp-media] media-id lookup failed inbox=#{inbox.id} media_id=#{media_id} " \
        "status=#{url_response.code} body=#{url_response.body.to_s.first(300)}"
      )
      return
    end

    media_url = url_response.parsed_response['url']
    if media_url.blank?
      Rails.logger.warn("[whatsapp-media] no url in media response inbox=#{inbox.id} media_id=#{media_id}")
      return
    end

    download_media_bytes(media_url, attachment_payload)
  end

  # Downloads the binary from Meta's CDN with a UA header and bounded retries. The GET
  # media-id lookup above already proved the token/network are healthy, so a failure here
  # is the CDN/container-path issue; we retry on Down errors before giving up (with a WARN).
  def download_media_bytes(media_url, attachment_payload)
    attempt = 0
    begin
      attempt += 1
      downloaded_file = Down.download(
        media_url,
        headers: media_download_headers,
        max_redirects: 5
      )
      # WhatsApp Cloud sends the original filename in the payload; preserve it so accented
      # names keep their correct extension instead of relying on the mangled remote metadata.
      filename = attachment_payload[:filename]
      downloaded_file.define_singleton_method(:original_filename) { filename } if filename.present?
      downloaded_file
    rescue Down::Error, Errno::ECONNRESET, Net::OpenTimeout, Net::ReadTimeout => e
      if attempt < MEDIA_DOWNLOAD_RETRIES
        sleep(0.5 * attempt)
        retry
      end
      Rails.logger.warn(
        "[whatsapp-media] binary download failed after #{attempt} attempts inbox=#{inbox.id} " \
        "media_id=#{attachment_payload[:id]} error=#{e.class}: #{e.message}"
      )
      nil
    end
  end

  # Lookup GET to graph.facebook.com — keep the channel's api_headers (bearer + JSON).
  def media_lookup_headers
    inbox.channel.api_headers
  end

  # Binary GET from the CDN — bearer token only, no JSON content-type, plus a UA the
  # lookaside CDN accepts.
  def media_download_headers
    { 'Authorization' => "Bearer #{inbox.channel.provider_config['api_key']}", 'User-Agent' => MEDIA_USER_AGENT }
  end
end
