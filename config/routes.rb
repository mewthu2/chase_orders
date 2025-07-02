require 'sidekiq/web'

Rails.application.routes.draw do
  devise_for :user, skip: [:registrations]
  root to: 'home#index'

  authenticate :user do
    mount Sidekiq::Web => '/sidekiq'
  end

  resources :dashboard, only: [:index] do
    collection do
      get :ranking_sellers
      get :order_correios_tracking
      get :order_correios_create
      get :send_xml
      get :push_tracking
      get :invoice_emition
      get :api_correios
      get :tracking
      get :stock
    end
  end

  resources :products do
    collection do
      post :run_product_update
    end
  end

  resources :motors, only: [:index]
  resources :orders

  resources :attempts, only: [:index] do
    collection do
      get :reprocess
      get :verify_attempts
    end
  end

  resources :discounts, only: [:index] do
    collection do
      post :search
      patch :toggle_status
      post :sync
      get :logs
    end
  end

  resources :logs, only: [:index]

  resources :users do
    member do
      patch :toggle_admin
      patch :toggle_status
    end
  end
end