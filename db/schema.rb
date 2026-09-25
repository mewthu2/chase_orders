# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_09_25_130000) do
  create_table "active_storage_attachments", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "address_corrections", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "tiny_order_id", null: false
    t.string "endereco"
    t.string "numero"
    t.string "complemento"
    t.string "bairro"
    t.string "cep"
    t.string "cidade"
    t.string "uf"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "awaiting_tiny_fix_at"
    t.text "awaiting_tiny_fix_message"
    t.datetime "tiny_fixed_at"
    t.index ["awaiting_tiny_fix_at"], name: "index_address_corrections_on_awaiting_tiny_fix_at"
    t.index ["tiny_order_id"], name: "index_address_corrections_on_tiny_order_id", unique: true
  end

  create_table "api_users", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "email"
    t.string "password_digest"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "attempts", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "kinds"
    t.bigint "status"
    t.text "requisition"
    t.text "params"
    t.string "error"
    t.string "status_code"
    t.text "message"
    t.string "exception"
    t.string "classification"
    t.string "cause"
    t.string "url"
    t.string "user"
    t.integer "tiny_order_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "order_correios_id"
    t.integer "id_nota_fiscal"
    t.text "xml_nota", size: :long
    t.boolean "xml_sended", default: false
    t.string "tracking"
    t.integer "id_nota_tiny2"
    t.boolean "is_transportadora", default: false
    t.index ["kinds", "status", "order_correios_id"], name: "index_attempts_on_kinds_status_order_correios_id"
    t.index ["kinds"], name: "index_attempts_on_kinds"
    t.index ["tiny_order_id"], name: "index_attempts_on_tiny_order_id"
  end

  create_table "b2b_order_items", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "b2b_order_id", null: false
    t.string "sku", null: false
    t.string "name"
    t.integer "quantity", null: false
    t.decimal "price", precision: 10, scale: 2, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "discount", precision: 10, scale: 2, default: "0.0", null: false
    t.index ["b2b_order_id"], name: "index_b2b_order_items_on_b2b_order_id"
  end

  create_table "b2b_orders", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.integer "kind", null: false
    t.integer "status", default: 0, null: false
    t.bigint "client_id"
    t.bigint "transfer_location_id"
    t.bigint "user_id", null: false
    t.string "carrier_name"
    t.string "carrier_shipping_method"
    t.integer "freight_paid_by"
    t.decimal "freight_value", precision: 10, scale: 2
    t.string "tiny_reference_id"
    t.string "tiny_reference_number"
    t.text "error_message"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "carrier_id"
    t.string "salesperson_name"
    t.integer "price_list", default: 0, null: false
    t.boolean "different_shipping_address", default: false, null: false
    t.string "shipping_street"
    t.string "shipping_number"
    t.string "shipping_complement"
    t.string "shipping_neighbourhood"
    t.string "shipping_city"
    t.string "shipping_state"
    t.string "shipping_zip"
    t.string "tracking_code"
    t.string "freight_service"
    t.index ["carrier_id"], name: "index_b2b_orders_on_carrier_id"
    t.index ["client_id"], name: "index_b2b_orders_on_client_id"
    t.index ["transfer_location_id"], name: "index_b2b_orders_on_transfer_location_id"
    t.index ["user_id"], name: "index_b2b_orders_on_user_id"
  end

  create_table "campaign_users", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "marketing_campaign_id", null: false
    t.bigint "user_id", null: false
    t.integer "tasks_assigned", default: 0
    t.integer "tasks_completed", default: 0
    t.integer "tasks_converted", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["marketing_campaign_id", "user_id"], name: "index_campaign_users_on_campaign_and_user", unique: true
    t.index ["marketing_campaign_id"], name: "index_campaign_users_on_marketing_campaign_id"
    t.index ["user_id"], name: "index_campaign_users_on_user_id"
  end

  create_table "carriers", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "name", null: false
    t.string "registration", null: false
    t.string "state_registration"
    t.string "street", null: false
    t.string "number", null: false
    t.string "complement"
    t.string "neighbourhood", null: false
    t.string "city", null: false
    t.string "state", null: false
    t.string "zip", null: false
    t.string "phone"
    t.string "email"
    t.boolean "active", default: true, null: false
    t.string "tiny_contact_id"
    t.datetime "transmitted_at"
    t.text "tiny_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "clients", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "responsible_name", null: false
    t.string "business_name"
    t.string "registration"
    t.string "state_registration"
    t.string "municipal_registration"
    t.string "street"
    t.string "neighbourhood"
    t.string "number"
    t.string "city"
    t.string "state"
    t.string "zip"
    t.string "email"
    t.string "phone"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "city_ibge_code"
    t.integer "ie_indicator", default: 9, null: false
    t.index ["registration"], name: "index_clients_on_registration"
    t.index ["responsible_name"], name: "index_clients_on_responsible_name"
  end

  create_table "companies", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "legal_name", null: false
    t.string "trade_name"
    t.string "cnpj", null: false
    t.string "state_registration"
    t.string "municipal_registration"
    t.string "cnae"
    t.integer "tax_regime", default: 1, null: false
    t.string "street", null: false
    t.string "number", null: false
    t.string "complement"
    t.string "neighbourhood", null: false
    t.string "city", null: false
    t.string "city_ibge_code", null: false
    t.string "state", null: false
    t.string "zip", null: false
    t.string "phone"
    t.string "email"
    t.integer "environment", default: 2, null: false
    t.integer "nfe_series", default: 1, null: false
    t.integer "next_nfe_number", default: 1, null: false
    t.string "cfop_sale_in_state", default: "5102", null: false
    t.string "cfop_sale_out_of_state", default: "6102", null: false
    t.string "cfop_transfer_in_state", default: "5152", null: false
    t.string "cfop_transfer_out_of_state", default: "6152", null: false
    t.string "operation_nature_sale", default: "Venda de mercadoria", null: false
    t.string "operation_nature_transfer", default: "Transferência de mercadoria", null: false
    t.string "icms_situation", default: "102", null: false
    t.string "pis_cst", default: "49", null: false
    t.string "cofins_cst", default: "49", null: false
    t.boolean "active", default: true, null: false
    t.text "certificate_password"
    t.datetime "certificate_expires_at"
    t.string "certificate_subject"
    t.string "certificate_cnpj"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cnpj"], name: "index_companies_on_cnpj", unique: true
  end

  create_table "customers", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "shopify_customer_id"
    t.string "name"
    t.string "email"
    t.string "phone"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "first_name"
    t.string "last_name"
    t.string "currency"
    t.string "tags"
    t.integer "orders_count"
    t.decimal "total_spent", precision: 15, scale: 2
    t.boolean "verified_email"
    t.boolean "tax_exempt"
    t.datetime "shopify_created_at"
    t.datetime "shopify_updated_at"
    t.string "default_address_name"
    t.string "default_address_company"
    t.string "default_address_phone"
    t.string "default_address_address1"
    t.string "default_address_address2"
    t.string "default_address_city"
    t.string "default_address_province"
    t.string "default_address_country"
    t.string "default_address_zip"
    t.string "default_address_country_code"
    t.string "default_address_province_code"
    t.json "addresses"
    t.index ["shopify_customer_id"], name: "index_customers_on_shopify_customer_id", unique: true
  end

  create_table "discounts", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "shopify_node_id", null: false
    t.string "shopify_price_rule_id"
    t.string "code", null: false
    t.string "title", null: false
    t.text "summary"
    t.boolean "is_active", default: true
    t.boolean "is_expired", default: false
    t.string "status", default: "ACTIVE"
    t.datetime "starts_at"
    t.datetime "ends_at"
    t.datetime "shopify_created_at"
    t.datetime "shopify_updated_at"
    t.string "discount_type"
    t.decimal "discount_value", precision: 10, scale: 4
    t.string "currency_code", default: "BRL"
    t.string "applies_to"
    t.decimal "min_purchase_amount", precision: 10, scale: 2
    t.integer "min_quantity"
    t.string "customer_eligibility", default: "Todos os clientes"
    t.integer "usage_limit"
    t.integer "usage_count", default: 0
    t.boolean "one_per_customer", default: false
    t.boolean "combines_with_product", default: false
    t.boolean "combines_with_shipping", default: false
    t.boolean "combines_with_order", default: false
    t.json "shopify_data"
    t.datetime "last_synced_at"
    t.boolean "needs_sync", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_discounts_on_code"
    t.index ["ends_at"], name: "index_discounts_on_ends_at"
    t.index ["is_active"], name: "index_discounts_on_is_active"
    t.index ["is_expired"], name: "index_discounts_on_is_expired"
    t.index ["last_synced_at"], name: "index_discounts_on_last_synced_at"
    t.index ["needs_sync"], name: "index_discounts_on_needs_sync"
    t.index ["shopify_node_id"], name: "index_discounts_on_shopify_node_id", unique: true
    t.index ["starts_at"], name: "index_discounts_on_starts_at"
  end

  create_table "fiscal_notes", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.bigint "b2b_order_id"
    t.integer "number", null: false
    t.integer "series", null: false
    t.string "access_key", limit: 44
    t.integer "environment", default: 2, null: false
    t.string "operation_nature"
    t.string "cfop_summary"
    t.integer "status", default: 0, null: false
    t.string "protocol"
    t.decimal "total_value", precision: 12, scale: 2, default: "0.0", null: false
    t.text "error_message"
    t.datetime "issued_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["b2b_order_id"], name: "index_fiscal_notes_on_b2b_order_id"
    t.index ["company_id", "series", "number"], name: "index_fiscal_notes_on_company_id_and_series_and_number", unique: true
    t.index ["company_id"], name: "index_fiscal_notes_on_company_id"
    t.index ["status"], name: "index_fiscal_notes_on_status"
  end

  create_table "internal_transfer_events", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "internal_transfer_id", null: false
    t.bigint "internal_transfer_shipment_id"
    t.bigint "user_id"
    t.string "action", null: false
    t.text "message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["internal_transfer_id"], name: "index_internal_transfer_events_on_internal_transfer_id"
    t.index ["internal_transfer_shipment_id"], name: "idx_on_internal_transfer_shipment_id_8854cee26a"
    t.index ["user_id"], name: "index_internal_transfer_events_on_user_id"
  end

  create_table "internal_transfer_items", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "internal_transfer_shipment_id", null: false
    t.bigint "product_id", null: false
    t.integer "quantity", null: false
    t.integer "status", default: 0, null: false
    t.integer "available_before"
    t.text "error_message"
    t.string "reserve_adjustment_id"
    t.string "receive_adjustment_id"
    t.datetime "reserved_at"
    t.datetime "received_at"
    t.datetime "cancelled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["internal_transfer_shipment_id", "product_id"], name: "idx_transfer_items_unique_product", unique: true
    t.index ["internal_transfer_shipment_id"], name: "index_internal_transfer_items_on_internal_transfer_shipment_id"
    t.index ["product_id"], name: "index_internal_transfer_items_on_product_id"
  end

  create_table "internal_transfer_shipments", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "internal_transfer_id", null: false
    t.bigint "origin_location_id", null: false
    t.integer "status", default: 0, null: false
    t.string "tracking_code"
    t.bigint "reserved_by_id"
    t.bigint "sent_by_id"
    t.bigint "received_by_id"
    t.bigint "cancelled_by_id"
    t.datetime "reserved_at"
    t.datetime "sent_at"
    t.datetime "received_at"
    t.datetime "cancelled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cancelled_by_id"], name: "index_internal_transfer_shipments_on_cancelled_by_id"
    t.index ["internal_transfer_id", "origin_location_id"], name: "idx_transfer_shipments_unique_origin", unique: true
    t.index ["internal_transfer_id"], name: "index_internal_transfer_shipments_on_internal_transfer_id"
    t.index ["origin_location_id"], name: "index_internal_transfer_shipments_on_origin_location_id"
    t.index ["received_by_id"], name: "index_internal_transfer_shipments_on_received_by_id"
    t.index ["reserved_by_id"], name: "index_internal_transfer_shipments_on_reserved_by_id"
    t.index ["sent_by_id"], name: "index_internal_transfer_shipments_on_sent_by_id"
  end

  create_table "internal_transfers", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "destination_location_id", null: false
    t.bigint "requested_by_id", null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["destination_location_id"], name: "index_internal_transfers_on_destination_location_id"
    t.index ["requested_by_id"], name: "index_internal_transfers_on_requested_by_id"
  end

  create_table "locations", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "slug", null: false
    t.string "name", null: false
    t.decimal "kpi_ratio", precision: 5, scale: 2
    t.datetime "kpi_updated_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "shopify_location_id"
    t.index ["kpi_ratio"], name: "index_locations_on_kpi_ratio"
    t.index ["shopify_location_id"], name: "index_locations_on_shopify_location_id", unique: true
    t.index ["slug"], name: "index_locations_on_slug", unique: true
  end

  create_table "logs", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "resource_type", null: false
    t.string "resource_id"
    t.string "action_type", null: false
    t.string "resource_name"
    t.text "details"
    t.text "old_values"
    t.text "new_values"
    t.string "ip_address"
    t.string "user_agent"
    t.text "error_message"
    t.boolean "success", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["action_type"], name: "index_logs_on_action_type"
    t.index ["created_at"], name: "index_logs_on_created_at"
    t.index ["resource_name"], name: "index_logs_on_resource_name"
    t.index ["resource_type", "resource_id"], name: "index_logs_on_resource_type_and_resource_id"
    t.index ["resource_type"], name: "index_logs_on_resource_type"
    t.index ["success"], name: "index_logs_on_success"
    t.index ["user_id", "resource_type"], name: "index_logs_on_user_id_and_resource_type"
    t.index ["user_id"], name: "index_logs_on_user_id"
  end

  create_table "marketing_campaigns", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "name", null: false
    t.text "objective"
    t.date "start_date", null: false
    t.date "end_date", null: false
    t.integer "users_per_week", default: 0
    t.integer "status", default: 0, null: false
    t.integer "campaign_type", default: 0, null: false
    t.integer "created_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.date "sync_from_date"
    t.integer "min_days_abandoned", default: 0
    t.index ["campaign_type"], name: "index_marketing_campaigns_on_campaign_type"
    t.index ["created_by_id"], name: "index_marketing_campaigns_on_created_by_id"
    t.index ["start_date", "end_date"], name: "index_marketing_campaigns_on_start_date_and_end_date"
    t.index ["status"], name: "index_marketing_campaigns_on_status"
    t.index ["sync_from_date"], name: "index_marketing_campaigns_on_sync_from_date"
  end

  create_table "marketing_tasks", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "marketing_campaign_id", null: false
    t.bigint "user_id"
    t.string "lead_email"
    t.string "lead_name"
    t.string "lead_phone"
    t.json "lead_data"
    t.integer "status", default: 0, null: false
    t.boolean "converted", default: false
    t.string "order_number"
    t.decimal "order_value", precision: 10, scale: 2
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "converted_at"
    t.text "notes"
    t.string "shopify_checkout_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "task_type", default: 0, null: false
    t.date "due_date"
    t.index ["converted"], name: "index_marketing_tasks_on_converted"
    t.index ["due_date"], name: "index_marketing_tasks_on_due_date"
    t.index ["lead_email"], name: "index_marketing_tasks_on_lead_email"
    t.index ["marketing_campaign_id", "status"], name: "index_marketing_tasks_on_marketing_campaign_id_and_status"
    t.index ["marketing_campaign_id"], name: "index_marketing_tasks_on_marketing_campaign_id"
    t.index ["shopify_checkout_id"], name: "index_marketing_tasks_on_shopify_checkout_id"
    t.index ["status"], name: "index_marketing_tasks_on_status"
    t.index ["task_type"], name: "index_marketing_tasks_on_task_type"
    t.index ["user_id", "status"], name: "index_marketing_tasks_on_user_id_and_status"
    t.index ["user_id", "task_type"], name: "index_marketing_tasks_on_user_id_and_task_type"
    t.index ["user_id"], name: "index_marketing_tasks_on_user_id"
  end

  create_table "motors", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "job_name"
    t.datetime "start_time"
    t.datetime "end_time"
    t.integer "running_time"
    t.text "link"
    t.string "step"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "order_items", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.bigint "product_id"
    t.string "price"
    t.integer "quantity"
    t.integer "tiny_product_id"
    t.integer "order_tiny_id"
    t.string "sku"
    t.boolean "canceled", default: false
    t.date "order_date_bh_shopping"
    t.date "order_date_lagoa_seca"
    t.date "order_date_rj"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["product_id"], name: "index_order_items_on_product_id"
  end

  create_table "order_parcels", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "order_pdv_id", null: false
    t.string "payment_method", null: false
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.string "integration_id"
    t.string "status", default: "pending"
    t.text "notes"
    t.json "payment_data"
    t.datetime "paid_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["integration_id"], name: "index_order_parcels_on_integration_id"
    t.index ["order_pdv_id", "status"], name: "index_order_parcels_on_order_pdv_id_and_status"
    t.index ["order_pdv_id"], name: "index_order_parcels_on_order_pdv_id"
    t.index ["status"], name: "index_order_parcels_on_status"
  end

  create_table "order_pdv_items", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "order_pdv_id", null: false
    t.bigint "product_id", null: false
    t.string "sku", null: false
    t.string "product_name", null: false
    t.decimal "price", precision: 10, scale: 2, null: false
    t.integer "quantity", null: false
    t.decimal "total", precision: 10, scale: 2, null: false
    t.string "option1"
    t.string "image_url"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_pdv_id", "product_id"], name: "index_order_pdv_items_on_order_pdv_id_and_product_id"
    t.index ["order_pdv_id"], name: "index_order_pdv_items_on_order_pdv_id"
    t.index ["product_id"], name: "index_order_pdv_items_on_product_id"
  end

  create_table "order_pdvs", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "customer_name"
    t.string "customer_email"
    t.string "customer_phone"
    t.string "customer_cpf"
    t.string "address1"
    t.string "city"
    t.string "state"
    t.string "zip"
    t.string "store_type", null: false
    t.string "payment_method"
    t.decimal "subtotal", precision: 10, scale: 2, null: false
    t.decimal "discount_amount", precision: 10, scale: 2, default: "0.0"
    t.string "discount_reason"
    t.decimal "total_price", precision: 10, scale: 2, null: false
    t.text "notes"
    t.text "order_note"
    t.string "status", limit: 20, default: "pending", null: false
    t.string "shopify_order_id"
    t.string "shopify_order_number"
    t.text "integration_error"
    t.datetime "integrated_at"
    t.integer "integration_attempts", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "address2"
    t.string "reservation_status"
    t.string "coupon_code"
    t.decimal "coupon_discount_amount", precision: 10, scale: 2, default: "0.0"
    t.text "multi_payments"
    t.text "inventory_reservations"
    t.text "reservation_error"
    t.bigint "client_id"
    t.string "tiny_order_id"
    t.string "tiny_order_number"
    t.string "tiny_status"
    t.datetime "tiny_integrated_at"
    t.text "tiny_error"
    t.index ["client_id"], name: "index_order_pdvs_on_client_id"
    t.index ["coupon_code"], name: "index_order_pdvs_on_coupon_code"
    t.index ["created_at"], name: "index_order_pdvs_on_created_at"
    t.index ["payment_method"], name: "index_order_pdvs_on_payment_method"
    t.index ["reservation_status"], name: "index_order_pdvs_on_reservation_status"
    t.index ["shopify_order_id"], name: "index_order_pdvs_on_shopify_order_id"
    t.index ["status"], name: "index_order_pdvs_on_status"
    t.index ["tiny_order_id"], name: "index_order_pdvs_on_tiny_order_id"
    t.index ["user_id"], name: "index_order_pdvs_on_user_id"
  end

  create_table "orders", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "location_id"
    t.bigint "kinds"
    t.integer "tiny_order_id"
    t.string "shopify_order_id"
    t.string "tags"
    t.string "tiny_creation_date"
    t.string "staff_id"
    t.string "staff_name"
    t.datetime "shopify_creation_date"
    t.json "iglu_payments"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "customer_id"
    t.json "note_attributes"
    t.json "discount_codes"
    t.decimal "current_total_price", precision: 10, scale: 2
    t.decimal "current_total_discounts", precision: 10, scale: 2
    t.index ["customer_id"], name: "index_orders_on_customer_id"
    t.index ["location_id"], name: "index_orders_on_location_id"
  end

  create_table "planner_order_items", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "planner_order_id", null: false
    t.string "name", null: false
    t.string "sku", null: false
    t.integer "quantity", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["planner_order_id"], name: "index_planner_order_items_on_planner_order_id"
    t.index ["sku"], name: "index_planner_order_items_on_sku"
  end

  create_table "planner_orders", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "user_id"
    t.string "reference", null: false
    t.integer "status", default: 0, null: false
    t.text "error_message"
    t.datetime "transmitted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "tiny_note_number"
    t.text "tiny_response"
    t.string "csv_filename"
    t.string "order_number"
    t.text "tags"
    t.index ["reference"], name: "index_planner_orders_on_reference", unique: true
    t.index ["status"], name: "index_planner_orders_on_status"
    t.index ["user_id"], name: "index_planner_orders_on_user_id"
  end

  create_table "product_updates", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "product_id", null: false
    t.bigint "user_id", null: false
    t.bigint "kinds"
    t.string "field"
    t.string "original_value"
    t.string "modified_value"
    t.string "json_return"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id"], name: "index_product_updates_on_product_id"
    t.index ["user_id"], name: "index_product_updates_on_user_id"
  end

  create_table "products", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "sku"
    t.string "tiny_lagoa_seca_product_id"
    t.integer "tiny_bh_shopping_id"
    t.integer "tiny_rj_id"
    t.string "tiny_2_id"
    t.string "shopify_product_id"
    t.string "shopify_variant_id"
    t.string "shopify_inventory_item_id"
    t.string "shopify_product_name"
    t.string "cost"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "price"
    t.string "compare_at_price"
    t.string "vendor"
    t.string "option1"
    t.string "option2"
    t.string "option3"
    t.string "stock_lagoa_seca"
    t.string "stock_bh_shopping"
    t.integer "stock_rj"
    t.integer "stock_fortaleza_rio_mar", default: 0
    t.integer "stock_porto_alegre_bourbon", default: 0
    t.integer "stock_eldorado_sp", default: 0
    t.string "stock_tiny_2"
    t.string "tags"
    t.text "image_url"
    t.integer "stock_shopping_analia_franco"
    t.integer "stock_iguatemi_campinas"
    t.string "ncm"
    t.string "cest"
    t.integer "origin", default: 0, null: false
    t.string "commercial_unit", default: "UN", null: false
    t.index ["stock_eldorado_sp"], name: "index_products_on_stock_eldorado_sp"
    t.index ["stock_fortaleza_rio_mar"], name: "index_products_on_stock_fortaleza_rio_mar"
    t.index ["stock_porto_alegre_bourbon"], name: "index_products_on_stock_porto_alegre_bourbon"
  end

  create_table "profile_ticket_sectors", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "profile_id", null: false
    t.bigint "ticket_sector_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["profile_id", "ticket_sector_id"], name: "index_profile_ticket_sectors_on_profile_and_sector", unique: true
    t.index ["profile_id"], name: "index_profile_ticket_sectors_on_profile_id"
    t.index ["ticket_sector_id"], name: "index_profile_ticket_sectors_on_ticket_sector_id"
  end

  create_table "profiles", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "name", null: false
    t.string "description"
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_profiles_on_name", unique: true
  end

  create_table "screen_permissions", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "profile_id", null: false
    t.string "screen_key", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["profile_id", "screen_key"], name: "index_screen_permissions_on_profile_id_and_screen_key", unique: true
    t.index ["profile_id"], name: "index_screen_permissions_on_profile_id"
  end

  create_table "stock_correction_items", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "stock_correction_id", null: false
    t.bigint "product_id", null: false
    t.boolean "checked", default: false
    t.boolean "needs_correction", default: false
    t.integer "current_stock"
    t.integer "corrected_stock"
    t.string "correction_reason"
    t.boolean "executed", default: false
    t.datetime "executed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "last_shopify_sync_at"
    t.string "shopify_sync_status", default: "pending"
    t.text "shopify_sync_error"
    t.integer "stock_before", default: 0
    t.index ["last_shopify_sync_at"], name: "index_stock_correction_items_on_last_shopify_sync_at"
    t.index ["needs_correction"], name: "index_stock_correction_items_on_needs_correction"
    t.index ["product_id"], name: "index_stock_correction_items_on_product_id"
    t.index ["shopify_sync_status"], name: "index_stock_correction_items_on_shopify_sync_status"
    t.index ["stock_before"], name: "index_stock_correction_items_on_stock_before"
    t.index ["stock_correction_id", "product_id"], name: "idx_on_stock_correction_id_product_id_f0f4e197f0", unique: true
    t.index ["stock_correction_id"], name: "index_stock_correction_items_on_stock_correction_id"
  end

  create_table "stock_corrections", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.date "correction_date", null: false
    t.string "reason", null: false
    t.string "location", null: false
    t.string "status", default: "pending"
    t.text "notes"
    t.datetime "executed_at"
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "deleted_at"
    t.datetime "integration_started_at"
    t.string "integration_status"
    t.text "integration_error"
    t.bigint "location_id"
    t.index ["correction_date"], name: "index_stock_corrections_on_correction_date"
    t.index ["deleted_at"], name: "index_stock_corrections_on_deleted_at"
    t.index ["integration_status"], name: "index_stock_corrections_on_integration_status"
    t.index ["location", "status"], name: "index_stock_corrections_on_location_and_status"
    t.index ["location_id"], name: "index_stock_corrections_on_location_id"
    t.index ["user_id"], name: "index_stock_corrections_on_user_id"
  end

  create_table "stock_sync_configs", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.boolean "enabled", default: false, null: false
    t.text "days_of_week", null: false
    t.text "hours", null: false
    t.datetime "last_execution"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "stock_withdrawal_items", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "stock_withdrawal_id", null: false
    t.bigint "product_id", null: false
    t.bigint "location_id", null: false
    t.integer "quantity", null: false
    t.integer "status", default: 0, null: false
    t.integer "available_before"
    t.text "error_message"
    t.string "shopify_adjustment_id"
    t.datetime "withdrawn_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "reverted_at"
    t.string "reversal_adjustment_id"
    t.bigint "reverted_by_id"
    t.index ["location_id"], name: "index_stock_withdrawal_items_on_location_id"
    t.index ["product_id"], name: "index_stock_withdrawal_items_on_product_id"
    t.index ["reverted_by_id"], name: "index_stock_withdrawal_items_on_reverted_by_id"
    t.index ["stock_withdrawal_id", "product_id", "location_id"], name: "idx_withdrawal_items_unique_product_location", unique: true
    t.index ["stock_withdrawal_id"], name: "index_stock_withdrawal_items_on_stock_withdrawal_id"
  end

  create_table "stock_withdrawals", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.date "withdrawal_date", null: false
    t.string "reason", default: "shrinkage", null: false
    t.text "notes"
    t.integer "status", default: 0, null: false
    t.bigint "user_id", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["status"], name: "index_stock_withdrawals_on_status"
    t.index ["user_id"], name: "index_stock_withdrawals_on_user_id"
  end

  create_table "ticket_messages", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "ticket_id", null: false
    t.bigint "user_id"
    t.integer "kind", default: 0, null: false
    t.text "body"
    t.integer "status_from"
    t.integer "status_to"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ticket_id"], name: "index_ticket_messages_on_ticket_id"
    t.index ["user_id"], name: "index_ticket_messages_on_user_id"
  end

  create_table "ticket_participants", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "ticket_id", null: false
    t.bigint "user_id", null: false
    t.integer "role", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ticket_id", "user_id"], name: "index_ticket_participants_on_ticket_id_and_user_id", unique: true
    t.index ["ticket_id"], name: "index_ticket_participants_on_ticket_id"
    t.index ["user_id"], name: "index_ticket_participants_on_user_id"
  end

  create_table "ticket_responsabilities", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.integer "response_time_hours", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "ticket_sector_id"
    t.index ["name"], name: "index_ticket_responsabilities_on_name", unique: true
    t.index ["ticket_sector_id"], name: "index_ticket_responsabilities_on_ticket_sector_id"
  end

  create_table "ticket_responsability_users", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "ticket_responsability_id", null: false
    t.bigint "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ticket_responsability_id", "user_id"], name: "index_ticket_resp_users_on_resp_and_user", unique: true
    t.index ["ticket_responsability_id"], name: "index_ticket_responsability_users_on_ticket_responsability_id"
    t.index ["user_id"], name: "index_ticket_responsability_users_on_user_id"
  end

  create_table "ticket_sectors", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_ticket_sectors_on_name", unique: true
  end

  create_table "tickets", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "title", null: false
    t.text "description", null: false
    t.bigint "ticket_responsability_id", null: false
    t.bigint "requester_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "due_at"
    t.datetime "overdue_notified_at"
    t.text "solution"
    t.datetime "resolved_at"
    t.datetime "closed_at"
    t.datetime "last_activity_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["due_at"], name: "index_tickets_on_due_at"
    t.index ["requester_id"], name: "index_tickets_on_requester_id"
    t.index ["status"], name: "index_tickets_on_status"
    t.index ["ticket_responsability_id"], name: "index_tickets_on_ticket_responsability_id"
  end

  create_table "tiny2_order_reviews", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "tiny_order_id", null: false
    t.integer "status", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tiny_order_id"], name: "index_tiny2_order_reviews_on_tiny_order_id", unique: true
  end

  create_table "transfer_locations", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "name", null: false
    t.string "registration", null: false
    t.string "state_registration"
    t.string "street", null: false
    t.string "number", null: false
    t.string "complement"
    t.string "neighbourhood", null: false
    t.string "city", null: false
    t.string "state", null: false
    t.string "zip", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "city_ibge_code"
  end

  create_table "user_profiles", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "profile_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["profile_id"], name: "index_user_profiles_on_profile_id"
    t.index ["user_id", "profile_id"], name: "index_user_profiles_on_user_id_and_profile_id", unique: true
    t.index ["user_id"], name: "index_user_profiles_on_user_id"
  end

  create_table "users", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.string "name"
    t.string "phone"
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "current_sign_in_at"
    t.datetime "last_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "last_sign_in_ip"
    t.string "confirmation_token"
    t.string "unlock_token"
    t.datetime "confirmed_at"
    t.datetime "confirmation_sent_at"
    t.string "unconfirmed_email"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "active", default: true, null: false
    t.json "allowed_locations"
    t.boolean "ticket_notifications_enabled", default: true, null: false
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["unlock_token"], name: "index_users_on_unlock_token", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "b2b_order_items", "b2b_orders"
  add_foreign_key "b2b_orders", "carriers"
  add_foreign_key "b2b_orders", "clients"
  add_foreign_key "b2b_orders", "transfer_locations"
  add_foreign_key "b2b_orders", "users"
  add_foreign_key "campaign_users", "marketing_campaigns"
  add_foreign_key "campaign_users", "users"
  add_foreign_key "fiscal_notes", "b2b_orders"
  add_foreign_key "fiscal_notes", "companies"
  add_foreign_key "internal_transfer_events", "internal_transfer_shipments"
  add_foreign_key "internal_transfer_events", "internal_transfers"
  add_foreign_key "internal_transfer_events", "users"
  add_foreign_key "internal_transfer_items", "internal_transfer_shipments"
  add_foreign_key "internal_transfer_items", "products"
  add_foreign_key "internal_transfer_shipments", "internal_transfers"
  add_foreign_key "internal_transfer_shipments", "locations", column: "origin_location_id"
  add_foreign_key "internal_transfer_shipments", "users", column: "cancelled_by_id"
  add_foreign_key "internal_transfer_shipments", "users", column: "received_by_id"
  add_foreign_key "internal_transfer_shipments", "users", column: "reserved_by_id"
  add_foreign_key "internal_transfer_shipments", "users", column: "sent_by_id"
  add_foreign_key "internal_transfers", "locations", column: "destination_location_id"
  add_foreign_key "internal_transfers", "users", column: "requested_by_id"
  add_foreign_key "logs", "users"
  add_foreign_key "marketing_tasks", "marketing_campaigns"
  add_foreign_key "marketing_tasks", "users"
  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "products"
  add_foreign_key "order_parcels", "order_pdvs"
  add_foreign_key "order_pdv_items", "order_pdvs"
  add_foreign_key "order_pdv_items", "products"
  add_foreign_key "order_pdvs", "clients"
  add_foreign_key "order_pdvs", "users"
  add_foreign_key "orders", "customers"
  add_foreign_key "orders", "locations"
  add_foreign_key "planner_order_items", "planner_orders"
  add_foreign_key "planner_orders", "users"
  add_foreign_key "product_updates", "products"
  add_foreign_key "product_updates", "users"
  add_foreign_key "profile_ticket_sectors", "profiles"
  add_foreign_key "profile_ticket_sectors", "ticket_sectors"
  add_foreign_key "screen_permissions", "profiles"
  add_foreign_key "stock_correction_items", "products"
  add_foreign_key "stock_correction_items", "stock_corrections"
  add_foreign_key "stock_corrections", "locations"
  add_foreign_key "stock_corrections", "users"
  add_foreign_key "stock_withdrawal_items", "locations"
  add_foreign_key "stock_withdrawal_items", "products"
  add_foreign_key "stock_withdrawal_items", "stock_withdrawals"
  add_foreign_key "stock_withdrawal_items", "users", column: "reverted_by_id"
  add_foreign_key "stock_withdrawals", "users"
  add_foreign_key "ticket_messages", "tickets"
  add_foreign_key "ticket_messages", "users"
  add_foreign_key "ticket_participants", "tickets"
  add_foreign_key "ticket_participants", "users"
  add_foreign_key "ticket_responsabilities", "ticket_sectors"
  add_foreign_key "ticket_responsability_users", "ticket_responsabilities"
  add_foreign_key "ticket_responsability_users", "users"
  add_foreign_key "tickets", "ticket_responsabilities"
  add_foreign_key "tickets", "users", column: "requester_id"
  add_foreign_key "user_profiles", "profiles"
  add_foreign_key "user_profiles", "users"
end
