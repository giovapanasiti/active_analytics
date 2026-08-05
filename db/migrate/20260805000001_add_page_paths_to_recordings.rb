class AddPagePathsToRecordings < ActiveRecord::Migration[8.1]
  def change
    add_column :active_analytics_recordings, :page_paths, :text
  end
end
