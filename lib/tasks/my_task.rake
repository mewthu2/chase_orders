namespace :test do
  task do_something: :environment do
    TestJob.perform_now
  end
end