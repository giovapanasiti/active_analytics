module ActiveAnalytics
  class ReferrerDay < ApplicationRecord
    validates :date, :referrer_host, presence: true

    def self.bump!(date:, referrer_host:)
      upsert_all(
        [ { date: date, referrer_host: referrer_host, views: 1 } ],
        unique_by: "index_aa_referrer_days_unique",
        on_duplicate: Arel.sql("views = views + 1")
      )
    end
  end
end
