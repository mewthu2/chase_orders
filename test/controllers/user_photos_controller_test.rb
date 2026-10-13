require 'test_helper'

class UserPhotosControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(name: 'Minha Foto', email: 'minha_foto@example.com', password: 'password123')
    sign_in @user
  end

  test 'profile form offers an accessible image picker with a circular preview' do
    get edit_user_path(@user)

    assert_response :success
    assert_select "form[enctype='multipart/form-data'] input[type=file][name='user[avatar]'][accept='image/jpeg,image/png,image/webp']"
    assert_select "label[for='user_avatar']", text: 'Foto de perfil'
    assert_select '.user-avatar--large [data-photo-preview][hidden]'
    assert_select "input[name='user[remove_avatar]']", count: 0
  end

  test 'user can upload a photo and see it in the navigation and profile after reload' do
    patch user_path(@user), params: { user: { avatar: photo_upload } }

    assert_redirected_to root_path
    assert @user.reload.avatar.attached?
    assert_equal 'image/png', @user.avatar.blob.content_type
    get edit_user_path(@user)
    assert_select '.nav-user .user-avatar img'
    assert_select '[data-photo-preview]:not([hidden])'
    assert_select "input[name='user[remove_avatar]']"
  end

  test 'user can replace a photo' do
    attach_photo
    original_blob = @user.avatar.blob

    patch user_path(@user), params: { user: { avatar: photo_upload } }

    assert_redirected_to root_path
    assert_not_equal original_blob.id, @user.reload.avatar.blob.id
  end

  test 'editing other fields or sending an empty file input keeps the saved photo' do
    attach_photo
    original_blob = @user.avatar.blob

    patch user_path(@user), params: { user: { name: 'Novo Nome', avatar: '' } }

    assert_redirected_to root_path
    assert_equal original_blob, @user.reload.avatar.blob
    assert_equal 'Novo Nome', @user.name
  end

  test 'user can remove their photo after a successful save' do
    attach_photo

    assert_enqueued_with(job: ActiveStorage::PurgeJob) do
      patch user_path(@user), params: { user: { remove_avatar: '1' } }
    end

    assert_redirected_to root_path
    refute @user.reload.avatar.attached?
    get edit_user_path(@user)
    assert_select '.nav-user .user-avatar img', count: 0
    assert_select '.nav-user .user-avatar [aria-label="Sem foto de perfil"]'
  end

  test 'a failed profile update does not remove the saved photo' do
    attach_photo
    original_blob = @user.avatar.blob

    patch user_path(@user), params: { user: { name: '', remove_avatar: '1' } }

    assert_response :unprocessable_entity
    assert_equal original_blob, @user.reload.avatar.blob
  end

  test 'a rejected replacement leaves the existing photo intact and renders errors' do
    attach_photo
    original_blob = @user.avatar.blob
    invalid_photo = Rack::Test::UploadedFile.new(StringIO.new('<svg></svg>'), 'image/svg+xml', original_filename: 'avatar.svg')

    patch user_path(@user), params: { user: { avatar: invalid_photo } }

    assert_response :unprocessable_entity
    assert_select '.alert-danger', text: /Foto de perfil deve ser uma imagem JPG, PNG ou WEBP/
    assert_equal original_blob, @user.reload.avatar.blob
  end

  test 'a new upload takes precedence over a stale removal flag' do
    attach_photo
    original_blob = @user.avatar.blob

    patch user_path(@user), params: { user: { avatar: photo_upload, remove_avatar: '1' } }

    assert_redirected_to root_path
    assert @user.reload.avatar.attached?
    assert_not_equal original_blob, @user.avatar.blob
  end

  test 'non-admin cannot upload or remove another users photo' do
    other = User.create!(name: 'Outra Pessoa', email: 'outra_foto@example.com', password: 'password123')
    other.avatar.attach(photo_upload)
    original_blob = other.avatar.blob

    patch user_path(other), params: { user: { avatar: photo_upload } }
    assert_redirected_to root_path
    assert_equal original_blob, other.reload.avatar.blob

    patch user_path(other), params: { user: { remove_avatar: '1' } }
    assert_redirected_to root_path
    assert_equal original_blob, other.reload.avatar.blob
  end

  test 'anonymous visitors cannot update a photo' do
    sign_out @user
    patch user_path(@user), params: { user: { avatar: photo_upload } }

    assert_redirected_to new_user_session_path
    refute @user.reload.avatar.attached?
  end

  test 'admin can create a user with a photo and view it in the user list and details' do
    @user.profiles << Profile.find(Profile::ADMIN)

    post users_path, params: { user: { name: 'Com Foto', email: 'nova_foto@example.com', password: 'password123', avatar: photo_upload } }

    assert_redirected_to users_path
    created_user = User.find_by!(email: 'nova_foto@example.com')
    assert created_user.avatar.attached?
    get users_path
    assert_select '.user-name-cell img[alt="Foto de Com Foto"]'
    get user_path(created_user)
    assert_select '.user-avatar--large img[alt="Foto de Com Foto"]'
  end

  test 'admin can upload and remove a photo for an existing user' do
    admin = User.create!(name: 'Admin Foto', email: 'admin_foto@example.com', password: 'password123')
    admin.profiles << Profile.find(Profile::ADMIN)
    sign_in admin

    get edit_user_path(@user)
    assert_select '[data-profile-photo]'
    patch user_path(@user), params: { user: { avatar: photo_upload } }
    assert_redirected_to users_path
    assert @user.reload.avatar.attached?

    patch user_path(@user), params: { user: { remove_avatar: '1' } }
    assert_redirected_to users_path
    refute @user.reload.avatar.attached?
  end

  private

  def photo_upload
    fixture_file_upload('tiny.png', 'image/png')
  end

  def attach_photo
    @user.avatar.attach(photo_upload)
  end
end
