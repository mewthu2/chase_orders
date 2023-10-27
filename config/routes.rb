Rails.application.routes.draw do
  devise_for :user, skip: [:registrations]
  root to: 'home#index'

  resources :dashboard, only: [:index] do
    collection do
      get 'tracking', to: 'dashboard#tracking', as: :tracking
    end
  end

  resources :attempts, only: [:index] do
    collection do
      get :send_xml
      get :verify_attempts
    end
  end
end
