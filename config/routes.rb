Rails.application.routes.draw do
  devise_for :user
  root to: 'home#index'
  resources :dashboard, only: [:index] do
    collection do
      get 'orders_tiny/:situacao', to: 'dashboard#orders_tiny', as: :orders_tiny
    end
  end
end
