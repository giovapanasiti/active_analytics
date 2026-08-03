module ActiveAnalytics
  class Insight < ApplicationRecord
    KINDS = %w[rage_click dead_click thrash u_turn form_abandon js_error summary].freeze

    attribute :details, :json

    belongs_to :recording

    validates :kind, presence: true, inclusion: { in: KINDS }
  end
end
