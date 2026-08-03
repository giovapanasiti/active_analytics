ActiveAnalytics::Engine.routes.draw do
  post "events", to: "events#create"
  post "pageviews", to: "pageviews#create"

  resources :recordings, only: [ :index, :show, :destroy ] do
    member do
      get :events   # JSON payload for the player
      post :analyze # run analysis on demand
    end
  end

  resources :heatmaps, only: [ :index ] do
    collection do
      # "show" is a Rails canonical resource action name, so a bare `get :show`
      # collapses to the collection's own path (colliding with #index). Force
      # an explicit path/name so this really lives at /heatmaps/show.
      get "show", action: :show, as: :show # /heatmaps/show?path=/pricing&device=desktop&kind=move
      get :data                            # JSON cells
    end
  end

  get "overview", to: "stats#index", as: :stats

  root to: "stats#index"
end
