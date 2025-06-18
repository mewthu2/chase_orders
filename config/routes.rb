require 'sidekiq/web'

Rails.application.routes.draw do
  devise_for :user, skip: [:registrations]
  root to: 'home#index'
  
  authenticate :user do
    mount Sidekiq::Web => '/sidekiq'
  end

  resources :dashboard, only: [:index] do
    collection do
      get :invoice_emition
      get :ranking_sellers
      get :dalila
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
end
