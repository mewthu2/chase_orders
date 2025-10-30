class SyncAbandonedCheckoutsJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info("Starting abandoned checkouts sync at #{Time.current}")

    campaigns = MarketingCampaign.status_active
                                 .where(campaign_type: :abandoned_cart)

    if campaigns.empty?
      Rails.logger.info("No active abandoned cart campaigns found")
      return
    end

    campaigns.each do |campaign|
      sync_campaign(campaign)
    end

    Rails.logger.info("Finished abandoned checkouts sync at #{Time.current}")
  end

  private

  def sync_campaign(campaign)
    Rails.logger.info("Syncing campaign: #{campaign.name} (ID: #{campaign.id})")

    begin
      distributor = MarketingTaskDistributorService.new(campaign)
      distributor.redistribute_pending_tasks

      sync_date = campaign.sync_from_date || campaign.start_date
      Rails.logger.info("Fetching checkouts from #{sync_date} for campaign #{campaign.id}")

      service = ShopifyAbandonedCheckoutService.new
      checkouts = service.fetch_abandoned_checkouts(since: sync_date.to_time)

      Rails.logger.info("Found #{checkouts.count} abandoned checkouts for campaign #{campaign.id}")

      distributor.distribute_tasks(checkouts)

      Rails.logger.info("Successfully synced campaign #{campaign.id}")
    rescue => e
      Rails.logger.error("Error syncing campaign #{campaign.id}: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
    end
  end
end
