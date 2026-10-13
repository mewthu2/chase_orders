module UsersHelper
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
