module ActiveAnalytics
  class VisitorDay < ApplicationRecord
    validates :date, :visitor_key, presence: true

    # Insert-ignore: the [date, visitor_key] unique index makes repeat visits a no-op,
    # so `where(date:).count` is the number of unique visitors that day.
    def self.mark!(date:, visitor_key:)
      insert_all(
        [ { date: date, visitor_key: visitor_key } ],
        unique_by: "index_aa_visitor_days_unique"
      )
    end
  end
end
