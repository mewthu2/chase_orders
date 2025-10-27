class MarketingTaskDistributorService
  def initialize(campaign)
    @campaign = campaign
  end

  def distribute_tasks(checkouts)
    return if checkouts.empty?
    
    marketing_users = @campaign.users.where(profile_id: [5, 6])
    
    if marketing_users.empty?
      Rails.logger.warn("Campaign #{@campaign.id} has no marketing users assigned")
      return
    end

    # First, try to assign pending tasks to users with available capacity
    redistribute_pending_tasks(marketing_users)

    # Then, create new tasks from checkouts
    distribute_new_checkouts(checkouts, marketing_users)
  end

  def redistribute_pending_tasks(marketing_users = nil)
    marketing_users ||= @campaign.users.where(profile_id: [5, 6])
    return if marketing_users.empty?

    # Get all pending tasks without assigned user
    pending_tasks = MarketingTask.where(
      marketing_campaign_id: @campaign.id,
      user_id: nil,
      status: :pending
    ).order(created_at: :asc)

    return if pending_tasks.empty?

    Rails.logger.info("Redistributing #{pending_tasks.count} pending tasks for campaign #{@campaign.id}")

    pending_tasks.each do |task|
      # Find user with most available capacity
      user = find_user_with_capacity(marketing_users)
      
      if user
        task.update(user_id: user.id)
        Rails.logger.info("Assigned pending task #{task.id} to user #{user.id}")
      else
        Rails.logger.info("No capacity available, task #{task.id} remains unassigned")
        break # Stop if no user has capacity
      end
    end
  end

  private

  def distribute_new_checkouts(checkouts, marketing_users)
    checkouts.each do |checkout|
      # Skip if task already exists for this checkout
      next if task_exists?(checkout[:checkout_id])

      # Try to find a user with available capacity
      user = find_user_with_capacity(marketing_users)
      
      if user
        create_task(user, checkout)
        Rails.logger.info("Created task for checkout #{checkout[:checkout_id]} assigned to user #{user.id}")
      else
        # Create task without user assignment (pending)
        create_unassigned_task(checkout)
        Rails.logger.info("Created unassigned task for checkout #{checkout[:checkout_id]} - no capacity available")
      end
    end
  end

  def find_user_with_capacity(marketing_users)
    users_per_week = @campaign.users_per_week || 10
    
    # Calculate available capacity for each user
    user_capacities = marketing_users.map do |user|
      active_tasks_count = count_active_tasks_for_user(user)
      available_slots = users_per_week - active_tasks_count
      
      {
        user: user,
        available_slots: available_slots,
        active_tasks: active_tasks_count
      }
    end

    # Filter users with available capacity and sort by most available slots
    available_users = user_capacities
      .select { |uc| uc[:available_slots] > 0 }
      .sort_by { |uc| [-uc[:available_slots], uc[:active_tasks]] }

    available_users.first&.dig(:user)
  end

  def count_active_tasks_for_user(user)
    user.marketing_tasks
        .where(marketing_campaign_id: @campaign.id)
        .where(status: [:pending, :in_progress])
        .where('created_at >= ?', Time.current.beginning_of_week)
        .count
  end

  def task_exists?(checkout_id)
    MarketingTask.where(marketing_campaign_id: @campaign.id)
                 .where("JSON_UNQUOTE(JSON_EXTRACT(lead_data, '$.checkout_id')) = ?", checkout_id.to_s)
                 .exists?
  end

  def create_task(user, checkout)
    MarketingTask.create!(
      marketing_campaign_id: @campaign.id,
      user_id: user.id,
      task_type: :abandoned_cart,
      status: :pending,
      lead_data: checkout,
      due_date: calculate_due_date
    )
  rescue => e
    Rails.logger.error("Error creating task for user #{user.id}: #{e.message}")
  end

  def create_unassigned_task(checkout)
    MarketingTask.create!(
      marketing_campaign_id: @campaign.id,
      user_id: nil,
      task_type: :abandoned_cart,
      status: :pending,
      lead_data: checkout,
      due_date: calculate_due_date
    )
  rescue => e
    Rails.logger.error("Error creating unassigned task: #{e.message}")
  end

  def calculate_due_date
    # Tasks should be completed in 3 days
    3.days.from_now.to_date
  end
end
