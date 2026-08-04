Rails.application.routes.draw do
  mount ActiveAnalytics::Engine => "/analytics"

  get "big", to: "home#big"

  root "home#index"
end
