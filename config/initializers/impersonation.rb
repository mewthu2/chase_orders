# O logout não limpa a sessão (sign_out_all_scopes = false): sem isto, quem logasse depois
# no mesmo navegador herdaria o "voltar para o super admin".
Warden::Manager.after_authentication { |_user, auth, _opts| auth.request.session.delete(:impersonator_id) }
Warden::Manager.before_logout { |_user, auth, _opts| auth.request.session.delete(:impersonator_id) }
