# frozen_string_literal: true

# Nt::WixPriceService (nt-7q0s) — the ONLY source of a service price Aria may state. Queries
# the Wix Bookings Services API (the source of truth) and returns the live fixed price for a
# named service. Aria/the bridge NEVER computes or invents a price; it asks this service.
#
# VERIFIED (rule 1): POST https://www.wixapis.com/bookings/v2/services/query with
# { query: { paging: { limit: 100 } } } returns services[].payment.fixed.price.value (INR).
# WIX_TOKEN + WIX_SITE_ID come from env (the OKF Wix token, IST JWT).
module Nt
  class WixPriceService
    WIX_QUERY_URL = 'https://www.wixapis.com/bookings/v2/services/query'
    CACHE_KEY = 'nt:wix_service_prices'
    CACHE_TTL = 1.hour

    class << self
      # Returns { name:, price: (Integer), currency: } for the best-matching service, or nil
      # if no confident match (so the caller falls back to "let me confirm + services link").
      def lookup(service_name)
        return nil if service_name.blank?

        prices = all_prices
        return nil if prices.blank?

        q = normalize(service_name)
        # exact-ish match first, then contains, then token overlap
        match = prices.find { |p| normalize(p[:name]) == q } ||
                prices.find { |p| normalize(p[:name]).include?(q) || q.include?(normalize(p[:name])) } ||
                best_token_match(prices, q)
        match
      rescue StandardError => e
        Rails.logger.error("[wix-price] lookup failed for #{service_name.inspect}: #{e.message}")
        nil
      end

      # All Wix services with a fixed price, cached (never per-request hammer Wix).
      def all_prices
        Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { fetch_from_wix }
      end

      private

      def fetch_from_wix
        token = ENV['WIX_TOKEN'] || GlobalConfigService.load('WIX_TOKEN', nil) rescue nil
        return [] if token.blank?

        # The IST-JWT is account-scoped; the Bookings Services query MUST be told which site to
        # read via the wix-site-id header, otherwise Wix returns HTTP 403 (empty body). Verified
        # (rule 1): Authorization alone -> 403; Authorization + wix-site-id -> 100 services incl.
        # LASH LIFTING=2500 INR on site 91ce5042-57ae-49d4-a482-185b17e44a0b.
        site_id = ENV['WIX_SITE_ID'] || GlobalConfigService.load('WIX_SITE_ID', nil) rescue nil
        headers = { 'Authorization' => token, 'Content-Type' => 'application/json' }
        headers['wix-site-id'] = site_id if site_id.present?

        resp = HTTParty.post(
          WIX_QUERY_URL,
          headers: headers,
          body: { query: { paging: { limit: 100 } } }.to_json,
          timeout: 15
        )
        unless resp.success?
          Rails.logger.warn("[wix-price] Wix query HTTP #{resp.code}: #{resp.body.to_s[0..150]}")
          return []
        end

        (resp.parsed_response['services'] || []).filter_map do |s|
          fixed = s.dig('payment', 'fixed', 'price')
          next unless fixed && fixed['value'].present?

          { name: s['name'].to_s, price: fixed['value'].to_s.delete(',').to_i, currency: fixed['currency'] || 'INR' }
        end
      rescue StandardError => e
        Rails.logger.error("[wix-price] fetch_from_wix failed: #{e.message}")
        []
      end

      def normalize(str)
        str.to_s.downcase.gsub(/[^a-z0-9 ]/, ' ').squeeze(' ').strip
      end

      # Pick the service sharing the most words with the query (>=2 shared words to be safe).
      def best_token_match(prices, q)
        qwords = q.split.reject { |w| w.length < 3 }.to_set
        return nil if qwords.empty?

        scored = prices.map { |p| [p, (normalize(p[:name]).split.to_set & qwords).size] }
        best, score = scored.max_by { |(_, s)| s }
        score.to_i >= 2 ? best : nil
      end
    end
  end
end
