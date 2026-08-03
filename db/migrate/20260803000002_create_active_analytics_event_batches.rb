class CreateActiveAnalyticsEventBatches < ActiveRecord::Migration[8.1]
  def change
    create_table :active_analytics_event_batches do |t|
      t.references :recording, null: false, index: true,
                    foreign_key: { to_table: :active_analytics_recordings }
      t.integer :seq, null: false
      t.text :events
      t.integer :byte_size, default: 0

      t.datetime :created_at, null: false
    end

    add_index :active_analytics_event_batches, [ :recording_id, :seq ], unique: true,
              name: "index_aa_event_batches_on_recording_id_and_seq"
  end
end
