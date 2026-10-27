class ApplicationMailer < ActionMailer::Base
  default from: ENV['MAILER_FROM'].presence || ENV['SMTP_USERNAME'].presence || 'chamados@chaseorders.com'
  layout 'mailer'
end
