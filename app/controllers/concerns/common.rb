module Common
  def params_per_page(per_page, max_value = 100)
    if per_page.to_i.between?(1, max_value.to_i)
      per_page.to_i
    elsif per_page.to_i > max_value
      max_value
    else
      30
    end
  end

  def json_response(object, status = :ok)
    response.headers['X-Total-Count'] = object.is_a?(ActiveRecord::Relation) && defined?(object.total_entries) && object.total_entries
    response.headers['Access-Control-Expose-Headers'] = 'X-Total-Count'
    render(json: object, status:)
  end
end
