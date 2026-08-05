namespace :active_analytics do
  desc "Analyze all stale unanalyzed recordings"
  task analyze: :environment do
    # Freeze the id list up front: analyzed records drop out of the scope, and
    # mutating a scope while find_each batches over it skips records.
    ids = ActiveAnalytics::Recording.stale.unanalyzed.pluck(:id)

    if ids.empty?
      puts "Nothing to analyze."

      still_active = ActiveAnalytics::Recording.unanalyzed.count
      if still_active.positive?
        timeout = ActiveAnalytics.config.session_timeout
        puts "#{still_active} unanalyzed recording(s) are still active: sessions become " \
             "analyzable after #{timeout}s of inactivity (config.session_timeout). " \
             "Use \"Run analysis\" on a recording page to analyze one immediately."
      end
    else
      ids.each do |id|
        ActiveAnalytics::AnalyzeRecordingJob.perform_now(id)
        recording = ActiveAnalytics::Recording.find_by(id: id)
        puts "Analyzed recording ##{id} (#{recording&.first_url || "unknown url"}) — " \
             "frustration score: #{recording&.frustration_score || "n/a"}"
      end
      puts "Analyzed #{ids.size} recording(s)."
    end
  end

  desc "Purge recordings past the configured retention period"
  task purge: :environment do
    count = ActiveAnalytics::Recording.purge_expired!
    puts "Purged #{count} recording(s)"

    cutoff = ActiveAnalytics.config.retention_days.days.ago.to_date
    visitor_count = ActiveAnalytics::VisitorDay.where("date < ?", cutoff).delete_all
    puts "Purged #{visitor_count} visitor day(s)"
  end
end
