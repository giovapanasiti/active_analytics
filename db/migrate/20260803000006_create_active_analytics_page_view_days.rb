class CreateActiveAnalyticsPageViewDays < ActiveRecord::Migration[8.1]
  def change
    create_table :active_analytics_page_view_days do |t|
      t.date :date, null: false
      t.string :page_path, null: false
      t.integer :views, null: false, default: 0
    end

    add_index :active_analytics_page_view_days, [ :date, :page_path ],
      unique: true, name: "index_aa_page_view_days_unique"
  end
end
