# frozen_string_literal: true

# Nt::WhatsappCatalogue (nt-0exh) — builds NailTalk's sendable service catalogue as native
# WhatsApp Cloud API INTERACTIVE LIST payloads, and resolves an incoming list_reply tap to
# the next thing to send (a sub-list or a booking-calendar link).
#
# WhatsApp list limits (verified against Meta Cloud API docs, 2026-07): sections <= 10,
# ROWS <= 10 TOTAL, header 60, body 4096, footer 60, action button 20, section title 24,
# row title 24, row description 72, row id 200. 103 services across 9 groups (> 10 rows) so
# the catalogue is a TWO-TIER menu:
#   Tier 1  category menu (1 list, 9 category rows)         -> row id "cat:<groupId>"
#   Tier 2  per-category service list (<= 10 rows, paged)   -> row id "svc:<slug>"
#   Tier 3  a tapped service resolves to its booking link   -> text reply
#
# Data source: lib/nt/service_catalogue.json (regenerate from service_ids.json x
# booking_urls.ts on service changes — see facebook-instagram-ads/scripts/gen_service_catalogue.py).
module Nt
  module WhatsappCatalogue
    MAX_ROWS = 10
    DATA_PATH = Rails.root.join('lib/nt/service_catalogue.json')

    module_function

    def data
      @data ||= JSON.parse(File.read(DATA_PATH))
    end

    def groups
      data['groups']
    end

    def group(group_id)
      groups.find { |g| g['id'] == group_id }
    end

    def service_by_slug(slug)
      @by_slug ||= groups.flat_map { |g| g['services'] }.to_h { |s| [s['slug'], s] }
      @by_slug[slug]
    end

    def clip(str, max)
      str.length <= max ? str : "#{str[0, max - 1]}…"
    end

    def inr(price)
      price.nil? ? '' : "₹#{price}"
    end

    # ── Tier 1: the catalogue menu (categories) ──────────────────────────────
    def category_menu_payload(to)
      rows = groups.map do |g|
        {
          'id' => "cat:#{g['id']}",
          'title' => clip("#{g['emoji']} #{g['name']}", 24),
          'description' => clip("#{g['services'].length} services", 72)
        }
      end
      {
        'messaging_product' => 'whatsapp',
        'to' => to,
        'type' => 'interactive',
        'interactive' => {
          'type' => 'list',
          'header' => { 'type' => 'text', 'text' => 'Nail Talk Menu 💅' },
          'body' => {
            'text' => "Here's our full service menu. Tap *View Services*, pick a category to see " \
                      'options + prices, then tap a service to get its booking link. ' \
                      'A ₹100 deposit confirms your slot. ✨'
          },
          'footer' => { 'text' => 'Nail Talk Hyderabad · 4 branches' },
          'action' => { 'button' => 'View Services', 'sections' => [{ 'title' => 'Choose a category', 'rows' => rows }] }
        }
      }
    end

    # ── Tier 2: a category's service list (paged to 10 rows) ──────────────────
    def service_list_payload(to, group_id, page = 0)
      g = group(group_id)
      return nil if g.nil?

      services = g['services']
      needs_paging = services.length > MAX_ROWS
      size = needs_paging ? (MAX_ROWS - 1) : MAX_ROWS # reserve a slot for a "More" row
      start = page * size
      slice = services[start, size] || []

      rows = slice.map do |s|
        desc = "#{inr(s['price'])} · tap for booking link".sub(/\A · /, '')
        { 'id' => "svc:#{s['slug']}", 'title' => clip(s['name'], 24), 'description' => clip(desc, 72) }
      end

      if start + size < services.length
        rows << {
          'id' => "cat:#{g['id']}:#{page + 1}",
          'title' => '➕ More options',
          'description' => clip("See more #{g['name'].downcase}", 72)
        }
      end

      page_note = needs_paging ? " (#{start + 1}–#{start + slice.length} of #{services.length})" : ''
      {
        'messaging_product' => 'whatsapp',
        'to' => to,
        'type' => 'interactive',
        'interactive' => {
          'type' => 'list',
          'header' => { 'type' => 'text', 'text' => clip("#{g['emoji']} #{g['name']}", 60) },
          'body' => { 'text' => "Tap any service to get its booking link for your branch.#{page_note} ✨" },
          'footer' => { 'text' => 'Nail Talk Hyderabad' },
          'action' => { 'button' => 'Pick a service', 'sections' => [{ 'title' => clip(g['name'], 24), 'rows' => rows }] }
        }
      }
    end

    # ── Tier 3: a tapped service -> booking-link text reply ───────────────────
    def booking_reply_payload(to, slug)
      s = service_by_slug(slug)
      return nil if s.nil?

      price = inr(s['price'])
      price_str = price.empty? ? '' : " (#{price})"
      body = "Lovely choice! ✨ Here's your *#{s['name']}*#{price_str} booking link — " \
             "pick your branch & slot, a ₹100 deposit confirms it:\n#{s['url']}"
      { 'messaging_product' => 'whatsapp', 'to' => to, 'type' => 'text', 'text' => { 'preview_url' => true, 'body' => body } }
    end

    # ── Tap router: turn an incoming list_reply id into the next payload ───────
    # Returns the payload Hash to POST, or nil if the id is not a catalogue tap
    # (so the caller falls back to Aria / normal handling).
    def payload_for_reply(to, reply_id)
      id = reply_id.to_s
      if id.start_with?('cat:')
        group_id, page = id.delete_prefix('cat:').split(':')
        return service_list_payload(to, group_id, (page || 0).to_i)
      end
      if id.start_with?('svc:')
        return booking_reply_payload(to, id.delete_prefix('svc:'))
      end

      nil
    end

    # True when a list_reply id belongs to the catalogue (so the incoming handler
    # can short-circuit it before Aria/the LLM sees it).
    def catalogue_reply?(reply_id)
      id = reply_id.to_s
      id.start_with?('cat:', 'svc:')
    end
  end
end
