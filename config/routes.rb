require 'sidekiq/web'

Rails.application.routes.draw do
  devise_for :user, skip: [:registrations]
  root to: 'home#index'

  authenticate :user do
    mount Sidekiq::Web => '/sidekiq'
  end

  namespace :api do
    post '/login', to: 'auth#login'
    post '/add_packaging', to: 'shopify_flow#add_packaging'
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
      get :stockend
      post :update_invoice_id
      post :delete_order_from_queue
      get :teste_embalagem
    end
  end

  resources :products, only: [:index] do
    collection do
      get :inventory
      post :search_inventory
      post :run_product_update
    end
  end

  resources :planner_orders do
    member do
      post :transmit
      get :export_xlsx
    end
  end

  resources :customers, only: [:index, :show]
  
  resources :stock_corrections do
    member do
      post :execute_all
      post :execute_item
      post :update_shopify_stock
      post :sync_item_with_shopify
      post :integrate_item_correction
      post :save_item_correction
      get :finalize_correction
      get :debug_locations
      get :reopen
      get :check_shopify_inventory
      patch :sync_with_shopify
      post :retry_shopify_sync
    end
  end
  
  resources :stock_correction_items, only: [:update, :destroy]
  
  resources :available_locations

  resources :motors, only: [:index]
  resources :orders, only: [:index] do
    collection do
      get :export
    end
  end
  resources :attempts, only: [:index] do
    collection do
      get :reprocess
      get :verify_attempts
      get :download_xml
    end
  end

  resources :stock_syncs, only: [:index] do
    collection do
      post :execute_now
      patch :toggle_status
      patch :update_config
    end
  end

  resources :marketing_campaigns do
    member do
      patch :toggle_status
      post :add_user
      delete :remove_user
      get :statistics
      delete :delete_all_tasks # Added route to delete all tasks from campaign
    end
  end
  
  resources :marketing_tasks, only: [:index, :show, :update] do
    collection do
      get :export
      get :dashboard
      get :my_tasks
    end
    member do
      post :start_work
      post :mark_converted
      post :mark_not_converted
      post :add_note
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
