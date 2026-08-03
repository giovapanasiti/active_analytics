module ActiveAnalytics
  class PageViewDay < ApplicationRecord
    validates :date, :page_path, presence: true

    def self.bump!(date:, page_path:)
      upsert_all(
        [ { date: date, page_path: page_path, views: 1 } ],
        unique_by: "index_aa_page_view_days_unique",
        on_duplicate: Arel.sql("views = views + 1")
      )
    end
  end
end
