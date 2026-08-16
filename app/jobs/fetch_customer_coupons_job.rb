class FetchCustomerCouponsJob < ApplicationJob
  queue_as :default

  RESULT_TTL = 5.minutes.to_i
  PROCESSING_TTL = 3.minutes.to_i

  def self.result_key(customer_id) = "customer_coupons:result:#{customer_id}"
  def self.processing_key(customer_id) = "customer_coupons:processing:#{customer_id}"

  def perform(customer_id)
    customer = Customer.find(customer_id)
    coupons = CustomerCouponEligibilityService.eligible_coupons_for(customer)

    $redis.set(self.class.result_key(customer_id), { coupons: }.to_json, ex: RESULT_TTL)
  rescue StandardError => e
    $redis.set(self.class.result_key(customer_id), { error: e.message }.to_json, ex: RESULT_TTL)
  ensure
    $redis.del(self.class.processing_key(customer_id))
  end
end
