module UsersHelper
  # "da****@gmail.com": mostra para onde foi o código da 2 etapas sem expor o e-mail inteiro.
  def masked_email(email)
    name, domain = email.to_s.split('@', 2)
    return email.to_s if domain.blank?

    "#{name[0, 2]}#{'*' * [name.length - 2, 3].max}@#{domain}"
  end

  def saved_avatar?(user)
    user.avatar.attached? && user.avatar.blob.persisted?
  end

  def user_avatar(user, large: false)
    content_tag :span, class: "user-avatar#{' user-avatar--large' if large}" do
      if saved_avatar?(user)
        image_tag user.avatar, alt: "Foto de #{user.name}"
      else
        content_tag :i, '', class: 'fas fa-user', role: 'img', 'aria-label': 'Sem foto de perfil'
      end
    end
  end
end
