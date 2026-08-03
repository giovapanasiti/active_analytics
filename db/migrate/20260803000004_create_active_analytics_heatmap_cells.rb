class CreateActiveAnalyticsHeatmapCells < ActiveRecord::Migration[8.1]
  def change
    create_table :active_analytics_heatmap_cells do |t|
      t.string :page_path, null: false
      t.string :device, null: false
      t.string :kind, null: false
      t.integer :x_bucket, null: false
      t.integer :y_bucket, null: false
      t.integer :count, null: false, default: 0
    end

    add_index :active_analytics_heatmap_cells,
      [ :page_path, :device, :kind, :x_bucket, :y_bucket ],
      unique: true, name: "index_aa_heatmap_cells_unique"
    add_index :active_analytics_heatmap_cells, [ :page_path, :device, :kind ],
      name: "index_aa_heatmap_cells_lookup"
  end
end
