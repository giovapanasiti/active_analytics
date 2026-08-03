class CreateActiveAnalyticsVisitorDays < ActiveRecord::Migration[8.1]
  def change
    create_table :active_analytics_visitor_days do |t|
      t.date :date, null: false
      t.string :visitor_key, null: false
    end

    add_index :active_analytics_visitor_days, [ :date, :visitor_key ],
      unique: true, name: "index_aa_visitor_days_unique"
    add_index :active_analytics_visitor_days, :date
  end
end
