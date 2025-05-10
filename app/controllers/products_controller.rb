class ProductsController < ApplicationController
  def index
    @products = filter_products
    @motors = Motor.where(job_name: "Atualização de produtos").order(id: :desc).limit(1)
    @job_running = check_if_job_running
  end
  
  def run_product_update
    SyncProductsSituationJob.perform_later
    flash[:notice] = "Atualização de produtos iniciada com sucesso!"
    redirect_to products_path
  end
  
  private
  
  def filter_products
    products = Product.all
    
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      products = products.where("sku ILIKE ? OR shopify_product_name ILIKE ? OR id::text LIKE ? OR shopify_product_id LIKE ?", 
                               search_term, search_term, search_term, search_term)
    end
    
    if params[:price_min].present?
      products = products.where("price::float >= ?", params[:price_min].to_f)
    end
    
    if params[:price_max].present?
      products = products.where("price::float <= ?", params[:price_max].to_f)
    end
    
    if params[:cost_min].present?
      products = products.where("cost::float >= ?", params[:cost_min].to_f)
    end
    
    if params[:cost_max].present?
      products = products.where("cost::float <= ?", params[:cost_max].to_f)
    end
    
    if params[:stock_rj].present?
      case params[:stock_rj]
      when 'in_stock'
        products = products.where("stock_rj::integer > 0")
      when 'out_of_stock'
        products = products.where("stock_rj::integer = 0 OR stock_rj IS NULL")
      when 'low_stock'
        products = products.where("stock_rj::integer > 0 AND stock_rj::integer <= 3")
      end
    end
    
    if params[:stock_bh].present?
      case params[:stock_bh]
      when 'in_stock'
        products = products.where("stock_bh_shopping::integer > 0")
      when 'out_of_stock'
        products = products.where("stock_bh_shopping::integer = 0 OR stock_bh_shopping IS NULL")
      when 'low_stock'
        products = products.where("stock_bh_shopping::integer > 0 AND stock_bh_shopping::integer <= 3")
      end
    end
    
    if params[:stock_ls].present?
      case params[:stock_ls]
      when 'in_stock'
        products = products.where("stock_lagoa_seca::integer > 0")
      when 'out_of_stock'
        products = products.where("stock_lagoa_seca::integer = 0 OR stock_lagoa_seca IS NULL")
      when 'low_stock'
        products = products.where("stock_lagoa_seca::integer > 0 AND stock_lagoa_seca::integer <= 3")
      end
    end
    
    if params[:platform].present?
      case params[:platform]
      when 'shopify'
        products = products.where.not(shopify_product_id: nil)
      when 'tiny_rj'
        products = products.where.not(tiny_rj_id: nil)
      when 'tiny_bh'
        products = products.where.not(tiny_bh_shopping_id: nil)
      when 'tiny_ls'
        products = products.where.not(tiny_lagoa_seca_product_id: nil)
      end
    end
    
    if params[:sort].present?
      direction = params[:direction] == 'desc' ? 'DESC' : 'ASC'
      case params[:sort]
      when 'id'
        products = products.order("id #{direction}")
      when 'sku'
        products = products.order("sku #{direction}")
      when 'name'
        products = products.order("shopify_product_name #{direction}")
      when 'cost'
        products = products.order("cost::float #{direction} NULLS LAST")
      when 'price'
        products = products.order("price::float #{direction} NULLS LAST")
      when 'updated_at'
        products = products.order("updated_at #{direction}")
      end
    else
      products = products.order(updated_at: :desc)
    end
    
    products
  end
  
  def check_if_job_running
    motor = Motor.where(job_name: "Atualização de produtos").order(id: :desc).first
    return false unless motor
    
    motor.start_time.present? && (motor.end_time.blank? || motor.running_time.blank?)
  end
end