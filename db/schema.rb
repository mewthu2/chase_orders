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

ActiveRecord::Schema[7.2].define(version: 2025_05_14_020938) do
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
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["unlock_token"], name: "index_users_on_unlock_token", unique: true
  end

  add_foreign_key "order_items", "orders"
  add_foreign_key "order_items", "products"
  add_foreign_key "product_updates", "products"
  add_foreign_key "product_updates", "users"
end
