class CreateActiveAnalyticsRecordings < ActiveRecord::Migration[8.1]
  def change
    create_table :active_analytics_recordings do |t|
      t.string :uuid, null: false
      t.datetime :started_at, null: false
      t.datetime :last_seen_at, null: false
      t.integer :duration_ms, default: 0
      t.string :first_url
      t.string :referrer
      t.string :user_agent
      t.integer :viewport_width
      t.integer :viewport_height
      t.string :device
      t.integer :pages_count, default: 1
      t.integer :events_count, default: 0
      t.integer :clicks_count, default: 0
      t.integer :errors_count, default: 0
      t.integer :frustration_score
      t.datetime :analyzed_at

      t.timestamps
    end

    add_index :active_analytics_recordings, :uuid, unique: true
    add_index :active_analytics_recordings, :last_seen_at
  end
end
