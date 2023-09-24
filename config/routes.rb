Rails.application.routes.draw do
  namespace :admin do
    root to: 'home#index'
    devise_for :user, path: 'admin', path_names: { sign_in: 'login' }
  end
end
