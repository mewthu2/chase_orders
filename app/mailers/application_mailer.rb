class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('MAILER_FROM', 'chamados@chaseorders.com')
  layout 'mailer'
end
