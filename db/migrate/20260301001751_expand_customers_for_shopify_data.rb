class ExpandCustomersForShopifyData < ActiveRecord::Migration[7.0]
  def up
    unless column_exists?(:customers, :first_name)
      add_column :customers, :first_name, :string
    end

    unless column_exists?(:customers, :last_name)
      add_column :customers, :last_name, :string
    end

    unless column_exists?(:customers, :currency)
      add_column :customers, :currency, :string
    end

    unless column_exists?(:customers, :tags)
      add_column :customers, :tags, :string
    end

    unless column_exists?(:customers, :orders_count)
      add_column :customers, :orders_count, :integer
    end

    unless column_exists?(:customers, :total_spent)
      add_column :customers, :total_spent, :decimal, precision: 15, scale: 2
    end

    unless column_exists?(:customers, :verified_email)
      add_column :customers, :verified_email, :boolean
    end

    unless column_exists?(:customers, :tax_exempt)
      add_column :customers, :tax_exempt, :boolean
    end

    unless column_exists?(:customers, :shopify_created_at)
      add_column :customers, :shopify_created_at, :datetime
    end

    unless column_exists?(:customers, :shopify_updated_at)
      add_column :customers, :shopify_updated_at, :datetime
    end

    unless column_exists?(:customers, :default_address_name)
      add_column :customers, :default_address_name, :string
    end

    unless column_exists?(:customers, :default_address_company)
      add_column :customers, :default_address_company, :string
    end

    unless column_exists?(:customers, :default_address_phone)
      add_column :customers, :default_address_phone, :string
    end

    unless column_exists?(:customers, :default_address_address1)
      add_column :customers, :default_address_address1, :string
    end

    unless column_exists?(:customers, :default_address_address2)
      add_column :customers, :default_address_address2, :string
    end

    unless column_exists?(:customers, :default_address_city)
      add_column :customers, :default_address_city, :string
    end

    unless column_exists?(:customers, :default_address_province)
      add_column :customers, :default_address_province, :string
    end

    unless column_exists?(:customers, :default_address_country)
      add_column :customers, :default_address_country, :string
    end

    unless column_exists?(:customers, :default_address_zip)
      add_column :customers, :default_address_zip, :string
    end

    unless column_exists?(:customers, :default_address_country_code)
      add_column :customers, :default_address_country_code, :string
    end

    unless column_exists?(:customers, :default_address_province_code)
      add_column :customers, :default_address_province_code, :string
    end

    unless column_exists?(:customers, :addresses)
      add_column :customers, :addresses, :json
    end

    unless index_exists?(:customers, :shopify_customer_id)
      add_index :customers, :shopify_customer_id, unique: true
    end
  end

  def down
    remove_index :customers, :shopify_customer_id if index_exists?(:customers, :shopify_customer_id)

    columns = [
      :first_name,
      :last_name,
      :currency,
      :tags,
      :orders_count,
      :total_spent,
      :verified_email,
      :tax_exempt,
      :shopify_created_at,
      :shopify_updated_at,
      :default_address_name,
      :default_address_company,
      :default_address_phone,
      :default_address_address1,
      :default_address_address2,
      :default_address_city,
      :default_address_province,
      :default_address_country,
      :default_address_zip,
      :default_address_country_code,
      :default_address_province_code,
      :addresses
    ]

    columns.each do |column|
      remove_column :customers, column if column_exists?(:customers, column)
    end
  end
end