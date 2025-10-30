class MarketingTaskDistributorService
  def initialize(campaign)
    @campaign = campaign
  end

  def distribute_tasks(checkouts)
    return if checkouts.empty?
    
    marketing_users = @campaign.users.marketing_users
    
    if marketing_users.empty?
      Rails.logger.warn("Campaign #{@campaign.id} has no marketing users assigned")
      return
    end

    Rails.logger.info("Creating tasks for #{checkouts.count} checkouts")

    # First, try to assign pending tasks to users with available capacity
    redistribute_pending_tasks(marketing_users)

    # Then, create new tasks from checkouts (all unassigned initially)
    create_tasks_from_checkouts(checkouts)
    
    # Finally, assign tasks that meet the minimum age requirement
    assign_tasks_by_age(marketing_users)
  end

  def redistribute_pending_tasks(marketing_users = nil)
    marketing_users ||= @campaign.users.marketing_users
    return if marketing_users.empty?

    pending_tasks = get_assignable_pending_tasks

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

  def create_tasks_from_checkouts(checkouts)
    checkouts.each do |checkout|
      # Skip if task already exists for this checkout
      next if task_exists?(checkout[:checkout_id])

      # Create task without user assignment (will be assigned later if meets age requirement)
      create_unassigned_task(checkout)
      Rails.logger.info("Created unassigned task for checkout #{checkout[:checkout_id]}")
    end
  end

  def assign_tasks_by_age(marketing_users)
    assignable_tasks = get_assignable_pending_tasks
    
    return if assignable_tasks.empty?
    
    Rails.logger.info("Found #{assignable_tasks.count} tasks that meet the #{@campaign.min_days_abandoned} days requirement")

    assignable_tasks.each do |task|
      user = find_user_with_capacity(marketing_users)
      
      if user
        task.update(user_id: user.id)
        Rails.logger.info("Assigned task #{task.id} (checkout age: #{task_age_in_days(task)} days) to user #{user.id}")
      else
        Rails.logger.info("No capacity available, task #{task.id} remains unassigned")
        break
      end
    end
  end

  def get_assignable_pending_tasks
    min_days = @campaign.min_days_abandoned || 0
    
    pending_tasks = MarketingTask.where(
      marketing_campaign_id: @campaign.id,
      user_id: nil,
      status: :pending
    ).order(created_at: :asc)

    return pending_tasks if min_days.zero?

    # Filter tasks by checkout age
    cutoff_date = min_days.days.ago
    
    pending_tasks.select do |task|
      checkout_created_at = task.lead_data['created_at']
      next false unless checkout_created_at

      checkout_date = Time.parse(checkout_created_at.to_s).in_time_zone rescue nil
      next false unless checkout_date

      checkout_date <= cutoff_date
    end
  end

  def task_age_in_days(task)
    checkout_created_at = task.lead_data['created_at']
    return 0 unless checkout_created_at

    checkout_date = Time.parse(checkout_created_at.to_s).in_time_zone rescue nil
    return 0 unless checkout_date

    ((Time.current - checkout_date) / 1.day).round(1)
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
