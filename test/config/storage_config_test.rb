require 'test_helper'

class StorageConfigTest < ActiveSupport::TestCase
  test 'bucketeer service reads the BUCKETEER_* variables and is private' do
    yml = ERB.new(Rails.root.join('config/storage.yml').read).result
    config = YAML.safe_load(yml, aliases: true)['bucketeer']

    assert_equal 'S3', config['service']
    assert_equal ENV['BUCKETEER_BUCKET_NAME'].to_s, config['bucket'].to_s
    assert_equal ENV['BUCKETEER_AWS_REGION'].to_s, config['region'].to_s
    assert_equal ENV['BUCKETEER_AWS_ACCESS_KEY_ID'].to_s, config['access_key_id'].to_s
    assert_equal false, config['public']
  end

  test 'development and production use the bucketeer service' do
    %w[development production].each do |env|
      assert_match(/active_storage\.service\s*=\s*:bucketeer/, Rails.root.join("config/environments/#{env}.rb").read)
    end
  end

  test 'attributes can be encrypted' do
    value = 'segredo'
    encrypted = ActiveRecord::Encryption.encryptor.encrypt(value)
    assert_not_equal value, encrypted
    assert_equal value, ActiveRecord::Encryption.encryptor.decrypt(encrypted)
  end

  test 'certificate_password is filtered from logs' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal '[FILTERED]', filter.filter(certificate_password: 'x')[:certificate_password]
  end
end
