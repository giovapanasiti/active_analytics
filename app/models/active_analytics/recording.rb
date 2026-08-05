module ActiveAnalytics
  class Recording < ApplicationRecord
    UUID_REGEX = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

    attribute :page_paths, :json

    has_many :event_batches, -> { order(:seq) }, dependent: :delete_all
    has_many :insights, dependent: :delete_all

    validates :uuid, presence: true, uniqueness: true, format: { with: UUID_REGEX }

    scope :stale, -> { where("last_seen_at < ?", ActiveAnalytics.config.session_timeout.seconds.ago) }
    scope :unanalyzed, -> { where(analyzed_at: nil) }

    def self.device_for(user_agent)
      return "desktop" if user_agent.blank?

      if user_agent.match?(/Mobile|Android/)
        "mobile"
      elsif user_agent.match?(/iPad|Tablet/)
        "tablet"
      else
        "desktop"
      end
    end

    def self.purge_expired!
      where("last_seen_at < ?", ActiveAnalytics.config.retention_days.days.ago).destroy_all.size
    end

    def events
      event_batches.order(:seq).flat_map(&:events)
    end

    def finished?
      last_seen_at < ActiveAnalytics.config.session_timeout.seconds.ago
    end

    def append_batch!(seq:, events:, byte_size:)
      batch = nil

      transaction do
        batch = event_batches.create!(seq: seq, events: events, byte_size: byte_size)

        nav_count = events.count { |e| e["e"] == "nav" }
        clicks = events.count { |e| e["e"] == "click" }
        errors = events.count { |e| e["e"] == "error" }
        max_t = events.filter_map { |e| e["t"] }.max

        self.events_count += events.size
        self.clicks_count += clicks
        self.errors_count += errors
        self.pages_count += nav_count
        self.last_seen_at = Time.current
        self.duration_ms = max_t if max_t && max_t > duration_ms.to_i

        save!
      end

      batch
    end
  end
end
