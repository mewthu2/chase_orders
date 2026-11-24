class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('MAILER_FROM', 'Honey.Chase <naoresponda@chasebrasil.com>')
  layout 'mailer'
end
