module ActiveAnalytics
  class EventBatch < ApplicationRecord
    attribute :events, :json

    belongs_to :recording

    validates :seq, presence: true, numericality: { greater_than_or_equal_to: 0, only_integer: true }
    validates :seq, uniqueness: { scope: :recording_id }
  end
end
