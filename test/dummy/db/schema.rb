# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_03_000009) do
  create_table "active_analytics_browser_days", force: :cascade do |t|
    t.string "browser", null: false
    t.date "date", null: false
    t.string "device", null: false
    t.integer "views", default: 0, null: false
    t.index ["date", "browser", "device"], name: "index_aa_browser_days_unique", unique: true
  end

  create_table "active_analytics_event_batches", force: :cascade do |t|
    t.integer "byte_size", default: 0
    t.datetime "created_at", null: false
    t.text "events"
    t.integer "recording_id", null: false
    t.integer "seq", null: false
    t.index ["recording_id", "seq"], name: "index_aa_event_batches_on_recording_id_and_seq", unique: true
    t.index ["recording_id"], name: "index_active_analytics_event_batches_on_recording_id"
  end

  create_table "active_analytics_heatmap_cells", force: :cascade do |t|
    t.integer "count", default: 0, null: false
    t.string "device", null: false
    t.string "kind", null: false
    t.string "page_path", null: false
    t.integer "x_bucket", null: false
    t.integer "y_bucket", null: false
    t.index ["page_path", "device", "kind", "x_bucket", "y_bucket"], name: "index_aa_heatmap_cells_unique", unique: true
    t.index ["page_path", "device", "kind"], name: "index_aa_heatmap_cells_lookup"
  end

  create_table "active_analytics_insights", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.text "details"
    t.string "kind", null: false
    t.integer "recording_id", null: false
    t.string "severity", default: "info"
    t.integer "ts_ms"
    t.index ["recording_id"], name: "index_active_analytics_insights_on_recording_id"
  end

  create_table "active_analytics_page_view_days", force: :cascade do |t|
    t.date "date", null: false
    t.string "page_path", null: false
    t.integer "views", default: 0, null: false
    t.index ["date", "page_path"], name: "index_aa_page_view_days_unique", unique: true
  end

  create_table "active_analytics_recordings", force: :cascade do |t|
    t.datetime "analyzed_at"
    t.integer "clicks_count", default: 0
    t.datetime "created_at", null: false
    t.string "device"
    t.integer "duration_ms", default: 0
    t.integer "errors_count", default: 0
    t.integer "events_count", default: 0
    t.string "first_url"
    t.integer "frustration_score"
    t.datetime "heatmap_aggregated_at"
    t.datetime "last_seen_at", null: false
    t.integer "pages_count", default: 1
    t.string "referrer"
    t.datetime "started_at", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.string "uuid", null: false
    t.integer "viewport_height"
    t.integer "viewport_width"
    t.index ["last_seen_at"], name: "index_active_analytics_recordings_on_last_seen_at"
    t.index ["uuid"], name: "index_active_analytics_recordings_on_uuid", unique: true
  end

  create_table "active_analytics_referrer_days", force: :cascade do |t|
    t.date "date", null: false
    t.string "referrer_host", null: false
    t.integer "views", default: 0, null: false
    t.index ["date", "referrer_host"], name: "index_aa_referrer_days_unique", unique: true
  end

  create_table "active_analytics_visitor_days", force: :cascade do |t|
    t.date "date", null: false
    t.string "visitor_key", null: false
    t.index ["date", "visitor_key"], name: "index_aa_visitor_days_unique", unique: true
    t.index ["date"], name: "index_active_analytics_visitor_days_on_date"
  end

  add_foreign_key "active_analytics_event_batches", "active_analytics_recordings", column: "recording_id"
  add_foreign_key "active_analytics_insights", "active_analytics_recordings", column: "recording_id"
end
