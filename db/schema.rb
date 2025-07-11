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

ActiveRecord::Schema[7.2].define(version: 2025_07_12_160911) do
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
    t.string "customer_name", null: false
    t.string "customer_email"
    t.string "customer_phone"
    t.string "customer_cpf"
    t.string "address1"
    t.string "city"
    t.string "state"
    t.string "zip"
    t.string "store_type", null: false
    t.string "payment_method", null: false
    t.decimal "subtotal", precision: 10, scale: 2, null: false
    t.decimal "discount_amount", precision: 10, scale: 2, default: "0.0"
    t.string "discount_reason"
    t.decimal "total_price", precision: 10, scale: 2, null: false
    t.text "notes"
    t.text "order_note"
    t.string "status", default: "pending"
    t.string "shopify_order_id"
    t.string "shopify_order_number"
    t.text "integration_error"
    t.datetime "integrated_at"
    t.integer "integration_attempts", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "address2"
    t.string "reservation_status"
    t.index ["created_at"], name: "index_order_pdvs_on_created_at"
    t.index ["shopify_order_id"], name: "index_order_pdvs_on_shopify_order_id"
    t.index ["status"], name: "index_order_pdvs_on_status"
    t.index ["user_id"], name: "index_order_pdvs_on_user_id"
  end

  create_table "orders", charset: "utf8mb4", collation: "utf8mb4_0900_ai_ci", force: :cascade do |t|
    t.bigint "kinds"
    t.integer "tiny_order_id"
    t.string "shopify_order_id"
    t.string "tags"
    t.string "tiny_creation_date"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
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
    t.string "stock_tiny_2"
    t.string "tags"
    t.text "image_url"
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
    t.integer "profile_id", default: 2
    t.boolean "active", default: true, null: false
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["profile_id"], name: "index_users_on_profile_id"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["unlock_token"], name: "index_users_on_unlock_token", unique: true
  end

  add_foreign_key "logs", "users"
  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "products"
  add_foreign_key "order_pdv_items", "order_pdvs"
  add_foreign_key "order_pdv_items", "products"
  add_foreign_key "order_pdvs", "users"
  add_foreign_key "product_updates", "products"
  add_foreign_key "product_updates", "users"
end
