class AddHeatmapAggregatedAtToRecordings < ActiveRecord::Migration[8.1]
  def change
    add_column :active_analytics_recordings, :heatmap_aggregated_at, :datetime
  end
end
