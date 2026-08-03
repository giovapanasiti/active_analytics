require "test_helper"

module ActiveAnalytics
  class HeatmapCellTest < ActiveSupport::TestCase
    def row(overrides = {})
      {
        page_path: "/pricing",
        device: "desktop",
        kind: "move",
        x_bucket: 1,
        y_bucket: 2,
        count: 3
      }.merge(overrides)
    end

    test "kind must be one of move/click/scroll" do
      cell = HeatmapCell.new(page_path: "/", device: "desktop", kind: "bogus", x_bucket: 0, y_bucket: 0)

      assert_not cell.valid?
      assert_includes cell.errors[:kind], "is not included in the list"

      %w[move click scroll].each do |kind|
        valid_cell = HeatmapCell.new(page_path: "/", device: "desktop", kind: kind, x_bucket: 0, y_bucket: 0)
        assert valid_cell.valid?, "expected kind=#{kind} to be valid"
      end
    end

    test "bump! inserts a new row when the unique key does not exist yet" do
      HeatmapCell.bump!([ row ])

      cell = HeatmapCell.find_by(page_path: "/pricing", device: "desktop", kind: "move", x_bucket: 1, y_bucket: 2)
      assert cell
      assert_equal 3, cell.count
    end

    test "bump! increments the count when the unique key already exists" do
      HeatmapCell.bump!([ row(count: 3) ])
      HeatmapCell.bump!([ row(count: 4) ])

      cell = HeatmapCell.find_by(page_path: "/pricing", device: "desktop", kind: "move", x_bucket: 1, y_bucket: 2)
      assert_equal 7, cell.count
      assert_equal 1, HeatmapCell.where(page_path: "/pricing", device: "desktop", kind: "move").count
    end

    test "bump! is a no-op for an empty row set" do
      assert_nothing_raised { HeatmapCell.bump!([]) }
      assert_equal 0, HeatmapCell.count
    end

    test "bump! keeps distinct cells (different bucket) as separate rows" do
      HeatmapCell.bump!([ row(x_bucket: 1), row(x_bucket: 2) ])

      assert_equal 2, HeatmapCell.where(page_path: "/pricing").count
    end
  end
end
