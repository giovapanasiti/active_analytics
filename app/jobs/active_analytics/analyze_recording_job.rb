module ActiveAnalytics
  class AnalyzeRecordingJob < ApplicationJob
    def perform(recording_id)
      recording = Recording.find_by(id: recording_id)
      return unless recording

      ActiveAnalytics::BehaviorAnalyzer.new(recording).analyze!
      ActiveAnalytics::Summarizer.new(recording).call
      ActiveAnalytics::HeatmapAggregator.new(recording).aggregate!
    end
  end
end
