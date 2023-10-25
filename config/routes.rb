Rails.application.routes.draw do
  devise_for :user, skip: [:registrations]
  root to: 'home#index'

  resources :dashboard, only: [:index] do
    collection do
      get 'orders_tiny/:situacao', to: 'dashboard#orders_tiny', as: :orders_tiny
      get 'get_tracking/:order_correios_id', to: 'dashboard#get_tracking', as: :get_tracking
    end
  end

  resources :attempts, only: [:index] do
    collection do
      get :send_xml
      get :verify_attempts
    end
  end
end
