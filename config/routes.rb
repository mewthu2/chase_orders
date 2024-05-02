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
      get :send_xml
      get :push_tracking
      get :tracking
      get :api_correios
      get :stock
    end
  end

  resources :products do
    collection do
      get :product_integration
    end
  end

  resources :attempts, only: [:index] do
    collection do
      get :reprocess
      get :verify_attempts
    end
  end
end
