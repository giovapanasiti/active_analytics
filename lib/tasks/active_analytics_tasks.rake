namespace :active_analytics do
  desc "Analyze all stale unanalyzed recordings"
  task analyze: :environment do
    ActiveAnalytics::Recording.stale.unanalyzed.find_each do |recording|
      ActiveAnalytics::AnalyzeRecordingJob.perform_now(recording.id)
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
