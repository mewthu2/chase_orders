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
      get :stockend
    end
  end

  resources :products, only: [:index] do
    collection do
      get :inventory
      post :search_inventory
      post :run_product_update
    end
  end
  
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
    end
  end
  
  resources :stock_correction_items, only: [:update]
  
  resources :available_locations

  resources :motors, only: [:index]
  resources :orders
  resources :attempts, only: [:index] do
    collection do
      get :reprocess
      get :verify_attempts
    end
  end

  # resources :order_pdvs, only: [:index, :show, :edit, :update] do
  #   member do
  #     post :integrate
  #     post :add_product
  #     delete :remove_product
  #   end
  #   collection do
  #     post :search_product
  #   end
    
  #   resources :order_parcels, only: [:index, :show, :update] do
  #     member do
  #       post :check_payment_status
  #       post :mark_as_paid
  #       post :mark_as_failed
  #     end
  #   end
  # end

  # resources :pos, only: [:index] do
  #   collection do
  #     get :get_cart_data
  #     post :restore_cart_from_backup
  #     post :search_product
  #     post :search_coupon
  #     post :apply_coupon
  #     delete :remove_coupon
  #     post :get_product_details
  #     post :add_to_cart
  #     patch :update_cart_quantity
  #     delete :remove_from_cart
  #     delete :clear_cart
  #     post :create_order
  #     post :create_order_without_integration
  #     post :check_stock
  #   end
  # end

  # resources :discounts, only: [:index] do
  #   collection do
  #     post :search
  #     patch :toggle_status
  #     post :sync
  #     get :logs
  #   end
  # end

  resources :stock_syncs, only: [:index] do
    collection do
      post :execute_now
      patch :toggle_status
      patch :update_config
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
