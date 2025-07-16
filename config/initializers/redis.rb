require 'redis'
require 'yaml'

redis_config_file = Rails.root.join('config', 'redis.yml')
if File.exist?(redis_config_file)
  redis_configs = YAML.load_file(redis_config_file)
  current_config = redis_configs[Rails.env] || redis_configs['development']
  
  redis_url = current_config['url']
  if redis_url == 'ENV["REDIS_URL"]'
    redis_url = ENV['REDIS_URL'] || 'redis://localhost:6379/1'
  end
  
  logger_level = case current_config['logger']
  when 'info' then Logger::INFO
  when 'warn' then Logger::WARN
  when 'error' then Logger::ERROR
  when false, 'false' then nil
  else Logger::INFO
  end
else
  redis_url = 'redis://localhost:6379/1'
  logger_level = Logger::INFO
end

redis_options = {
  url: redis_url,
  timeout: 5,
  reconnect_attempts: 3,
  reconnect_delay: 0.5,
  tcp_keepalive: 5,
  inherit_socket: false
}

if logger_level
  redis_options[:logger] = Logger.new(STDOUT).tap { |l| l.level = logger_level }
end

$redis = Redis.new(redis_options)

Rails.application.configure do
  config.cache_store = :redis_cache_store, {
    url: redis_url,
    timeout: 5,
    reconnect_attempts: 3,
    pool_size: 5,
    pool_timeout: 5
  }
end

begin
  $redis.ping
  Rails.logger.info "Redis conectado com sucesso: #{redis_url}"
rescue Redis::BaseError => e
  Rails.logger.error "Erro ao conectar com Redis: #{e.message}"
  Rails.logger.error "Verifique se o Redis está rodando em: #{redis_url}"
end

def redis_expire_if_exists(key, ttl)
  if $redis.exists(key)
    $redis.expire(key, ttl)
  end
rescue Redis::BaseError => e
  Rails.logger.error "Erro ao definir expiração para #{key}: #{e.message}"
end

# redis_expire_if_exists("cart:916bef605f5c18e00e3535528774c226", 3600)
# redis_expire_if_exists("coupon:916bef605f5c18e00e3535528774c226", 600)
