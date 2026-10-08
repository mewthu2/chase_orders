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

  resources :order_pdvs do
    member do
      get    :generate_pdf
      post   :integrate
      post   :integrate_tiny
      patch  :mark_as_paid
      patch  :attach_client
      post   :add_product
      delete :remove_product
      get    :items
    end
  end

  resources :pos, only: [:index] do
    collection do
      post :search_product
      post :add_to_cart
      patch :update_cart_quantity
      post  :remove_from_cart
      post  :clear_cart
      post  :create_order
    end
  end

  resources :dashboard, only: [:index] do
    collection do
      get :ranking_sellers
      get :correios_pipeline
      get :order_correios_tracking
      get :order_correios_create
      post :run_order_correios_create_now
      get :order_correios_create_b2b
      get :order_correios_create_queue_b2b
      post :approve_order_b2b
      post :ignore_order_b2b
      post :run_create_correios_b2b
      post :run_order_correios_create_b2b_now
      get :order_correios_stock_errors
      get :order_correios_stock_errors_b2b
      get :send_xml
      post :run_send_xml
      post :run_send_xml_now
      get :send_xml_b2b
      post :run_send_xml_b2b
      post :run_send_xml_b2b_now
      get :push_tracking
      post :run_push_tracking
      post :run_push_tracking_now
      get :push_tracking_b2b
      post :run_push_tracking_b2b
      post :run_push_tracking_b2b_now
      get :invoice_emition
      post :run_invoice_emition
      post :run_invoice_emition_now
      get :invoice_emition_b2b
      post :run_invoice_emition_b2b
      post :run_invoice_emition_b2b_now
      get :order_correios_tracking_b2b
      get :api_correios
      get :api_correios_b2b
      get :tracking
      get :stockend
      get :stuck_orders
      get :search_product
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

  resources :customers, only: [:index, :show] do
    member do
      get :coupons
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
      patch :sync_with_shopify
      post :retry_shopify_sync
    end
  end
  
  resources :stock_correction_items, only: [:update, :destroy]

  resources :stock_withdrawals do
    resources :items, controller: 'stock_withdrawal_items', only: [] do
      member { post :revert }
    end
    member { post :complete }
    collection do
      get :search_product
      get :live_stock
    end
  end
  
  resource :internal_transfer_config, only: [:edit, :update]
  resources :internal_transfers do
    member do
      post :approve
      post :reject
    end
    resources :shipments, controller: 'internal_transfer_shipments', only: [] do
      member do
        post :reserve
        post :ship
        post :receive
        post :cancel
      end
    end
    collection do
      get :search_product
      get :live_stock
    end
  end

  resources :available_locations

  resources :motors, only: [:index]

  resources :orders, only: [:index] do
    collection do
      get :export
      get :coupon_usage
    end
  end

  resources :clients do
    collection do
      get :search
    end
  end

  resources :attempts, only: [:index] do
    collection do
      get :reprocess
      get :verify_attempts
      get :download_xml
      get :bairro_lookup
      post :fix_bairro
      post :mark_tiny_fixed
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
      delete :delete_all_tasks
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
  
  resources :profiles
  resources :transfer_locations

  resources :carriers do
    member do
      post :transmit
    end
  end

  # Atacado e transferência de estoque são telas separadas sobre o mesmo
  # controller: o tipo do pedido vem do default da rota (order_kind), não do form.
  resources :b2b_orders, defaults: { order_kind: 'sale' } do
    collection do
      get :shipping_methods
      post :parse_items_spreadsheet
      get :product_stock
      get :search_product
      get :product_picker
      get :search_client
      post :import_client
    end
    member do
      post :transmit
      post :cancel_in_tiny
      get :romaneio
    end
  end

  resources :companies, except: [:show]

  resources :fiscal_products, only: [:index, :update] do
    member { post :import_from_tiny }
    collection { post :import_all_from_tiny }
  end

  resources :fiscal_notes, only: [:index, :show, :new, :create] do
    member do
      get :xml
    end
  end

  resources :stock_transfers, controller: 'b2b_orders', defaults: { order_kind: 'stock_transfer' },
                              only: [:index, :new, :create, :edit, :update, :destroy] do
    member do
      post :transmit
      get :romaneio
    end
  end

  resources :b2c_transfers, controller: 'b2b_orders', defaults: { order_kind: 'b2c_transfer' },
                            only: [:index, :new, :create, :edit, :update, :destroy] do
    member do
      post :transmit
      post :cancel_in_tiny
      get :romaneio
    end
  end

  resources :ticket_sectors, except: [:show]
  resources :ticket_responsabilities, except: [:show]
  resources :tickets, only: [:new, :create, :show, :destroy] do
    resources :ticket_messages, only: [:create], path: 'messages'
    resources :ticket_participants, only: [:create], path: 'participants'
  end

  resource :font_scale, only: [:update]

  resources :users do
    member do
      patch :toggle_admin
      patch :toggle_status
    end
  end
end