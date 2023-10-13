namespace :my_task do
  task do_something: :production do
    TestJob.perform_now
  end
end