module ActiveAnalytics
  class Engine < ::Rails::Engine
    isolate_namespace ActiveAnalytics

    initializer "active_analytics.helpers" do
      ActiveSupport.on_load(:action_controller_base) do
        helper ActiveAnalytics::Engine.helpers
      end
    end
  end
end
