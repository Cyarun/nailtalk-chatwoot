# frozen_string_literal: true

require 'rails_helper'

# nt-0exh: the service catalogue is the sendable payload surface for WhatsApp interactive
# lists. These specs pin the WhatsApp Cloud API hard limits (rows <= 10, titles <= 24, etc.)
# and the tap-routing contract so a data regen or edit can never ship a payload Meta rejects.
RSpec.describe Nt::WhatsappCatalogue do
  # WhatsApp Cloud API interactive-list limits (verified against Meta docs, 2026-07).
  LIMITS = { header: 60, body: 4096, footer: 60, button: 20, section_title: 24,
             row_title: 24, row_desc: 72, row_id: 200 }.freeze

  def assert_list_within_limits(payload)
    i = payload['interactive']
    expect(i['header']['text'].length).to be <= LIMITS[:header] if i['header']
    expect(i['body']['text'].length).to be <= LIMITS[:body]
    expect(i['footer']['text'].length).to be <= LIMITS[:footer] if i['footer']
    action = i['action']
    expect(action['button'].length).to be <= LIMITS[:button]

    total_rows = 0
    action['sections'].each do |section|
      expect((section['title'] || '').length).to be <= LIMITS[:section_title]
      section['rows'].each do |row|
        total_rows += 1
        expect(row['title'].length).to be <= LIMITS[:row_title]
        expect((row['description'] || '').length).to be <= LIMITS[:row_desc]
        expect(row['id'].length).to be <= LIMITS[:row_id]
      end
    end
    expect(total_rows).to be <= 10
  end

  describe '.category_menu_payload (Tier 1)' do
    subject(:menu) { described_class.category_menu_payload('918179245139') }

    it 'is a valid interactive list within all WhatsApp limits' do
      expect(menu.dig('interactive', 'type')).to eq('list')
      assert_list_within_limits(menu)
    end

    it 'has one row per catalogue group with a cat: id' do
      rows = menu.dig('interactive', 'action', 'sections', 0, 'rows')
      expect(rows.length).to eq(described_class.groups.length)
      expect(rows).to all(satisfy { |r| r['id'].start_with?('cat:') })
    end
  end

  describe '.service_list_payload (Tier 2)' do
    it 'paginates every group so each page stays within limits' do
      described_class.groups.each do |group|
        page = 0
        loop do
          payload = described_class.service_list_payload('918179245139', group['id'], page)
          expect(payload).not_to be_nil, "no payload for #{group['id']} p#{page}"
          assert_list_within_limits(payload)
          rows = payload.dig('interactive', 'action', 'sections', 0, 'rows')
          break unless rows.any? { |r| r['id'].start_with?("cat:#{group['id']}:") }

          page += 1
          break if page > 5 # safety
        end
      end
    end

    it 'returns nil for an unknown group' do
      expect(described_class.service_list_payload('x', 'not-a-group')).to be_nil
    end
  end

  describe '.booking_reply_payload (Tier 3)' do
    it 'resolves every service slug to a text reply containing its booking URL' do
      described_class.groups.each do |group|
        group['services'].each do |svc|
          payload = described_class.booking_reply_payload('918179245139', svc['slug'])
          expect(payload).not_to be_nil, "no booking reply for #{svc['slug']}"
          expect(payload.dig('text', 'body')).to include(svc['url'])
        end
      end
    end

    it 'returns nil for an unknown slug' do
      expect(described_class.booking_reply_payload('x', 'no-such-service')).to be_nil
    end
  end

  describe '.payload_for_reply (tap router)' do
    it 'routes a cat: id to a service list' do
      expect(described_class.payload_for_reply('x', 'cat:pedicures').dig('interactive', 'type')).to eq('list')
    end

    it 'routes a cat:<id>:<page> id to a paged service list' do
      payload = described_class.payload_for_reply('x', 'cat:nail-extensions:1')
      expect(payload.dig('interactive', 'type')).to eq('list')
    end

    it 'routes a svc: id to a booking-link text reply' do
      expect(described_class.payload_for_reply('x', 'svc:gel-pedicure').dig('type')).to eq('text')
    end

    it 'returns nil for a non-catalogue id' do
      expect(described_class.payload_for_reply('x', 'hello there')).to be_nil
    end
  end

  describe '.catalogue_reply?' do
    it { expect(described_class.catalogue_reply?('cat:pedicures')).to be(true) }
    it { expect(described_class.catalogue_reply?('svc:gel-pedicure')).to be(true) }
    it { expect(described_class.catalogue_reply?('just a message')).to be(false) }
    it { expect(described_class.catalogue_reply?(nil)).to be(false) }
  end

  describe 'catalogue data integrity' do
    it 'carries 103 services across the customer-facing groups' do
      total = described_class.groups.sum { |g| g['services'].length }
      expect(total).to eq(103)
    end

    it 'gives every service a booking-calendar URL' do
      described_class.groups.each do |group|
        group['services'].each do |svc|
          expect(svc['url']).to match(%r{\Ahttps://www\.nailtalk\.in/booking-calendar/})
        end
      end
    end
  end
end
