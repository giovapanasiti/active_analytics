module ActiveAnalytics
  class BrowserDay < ApplicationRecord
    validates :date, :browser, :device, presence: true

    def self.bump!(date:, browser:, device:)
      upsert_all(
        [ { date: date, browser: browser, device: device, views: 1 } ],
        unique_by: "index_aa_browser_days_unique",
        on_duplicate: Arel.sql("views = views + 1")
      )
    end
  end
end
