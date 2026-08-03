module ActiveAnalytics
  class HeatmapCell < ApplicationRecord
    KINDS = %w[move click scroll].freeze

    validates :page_path, :device, presence: true
    validates :kind, inclusion: { in: KINDS }
    validates :x_bucket, :y_bucket, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

    # rows: array of hashes with page_path/device/kind/x_bucket/y_bucket/count.
    # Single statement: inserts new cells and increments existing ones.
    def self.bump!(rows)
      return if rows.empty?

      upsert_all(
        rows,
        unique_by: "index_aa_heatmap_cells_unique",
        on_duplicate: Arel.sql("count = count + excluded.count")
      )
    end
  end
end
