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
end
