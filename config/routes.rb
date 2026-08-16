# frozen_string_literal: true

GoodPipeline::Engine.routes.draw do
  root "pipelines#index"

  resources :pipelines, only: %i[index show] do
    get :definitions, on: :collection

    member do
      post :rerun
      post :cancel
    end
  end

  patch :theme, to: "themes#update", as: :theme

  scope :frontend, controller: :frontends, defaults: { version: GoodPipeline::VERSION.tr(".", "-") } do
    get "static/:version/:id", action: :static, as: :frontend_static
  end
end
