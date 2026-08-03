class CreateActiveAnalyticsInsights < ActiveRecord::Migration[8.1]
  def change
    create_table :active_analytics_insights do |t|
      t.references :recording, null: false, index: true,
                    foreign_key: { to_table: :active_analytics_recordings }
      t.string :kind, null: false
      t.string :severity, default: "info"
      t.integer :ts_ms
      t.text :details
      t.text :body

      t.datetime :created_at, null: false
    end
  end
end
