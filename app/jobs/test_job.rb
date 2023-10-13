class TestJob < ActiveJob::Base
  def perform
    10.times do
      puts 'Teste Daniel'
    end
  end
end
