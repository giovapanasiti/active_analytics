class CreateActiveAnalyticsReferrerDays < ActiveRecord::Migration[8.1]
  def change
    create_table :active_analytics_referrer_days do |t|
      t.date :date, null: false
      t.string :referrer_host, null: false
      t.integer :views, null: false, default: 0
    end

    add_index :active_analytics_referrer_days, [ :date, :referrer_host ],
      unique: true, name: "index_aa_referrer_days_unique"
  end
end
