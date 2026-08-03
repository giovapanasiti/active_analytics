class CreateActiveAnalyticsBrowserDays < ActiveRecord::Migration[8.1]
  def change
    create_table :active_analytics_browser_days do |t|
      t.date :date, null: false
      t.string :browser, null: false
      t.string :device, null: false
      t.integer :views, null: false, default: 0
    end

    add_index :active_analytics_browser_days, [ :date, :browser, :device ],
      unique: true, name: "index_aa_browser_days_unique"
  end
end
