# frozen_string_literal: true

class RateLimiter
  MAX_PER_WINDOW = 50
  WINDOW_SIZE = 1.minute

  def initialize(app)
    @app = app
  end

  def call(env)
    @req = ActionDispatch::Request.new(env)
    rate_limited? ? response_limit_reached : response_normal
  end

  private

  def rate_limit_headers
    {
      'Rate-Limit-Reached' => rate_limited?,
      'Rate-Limit-Left' => requests_left,
      'Rate-Limit-Reset' => reset_time
    }
  end

  def rate_limited?
    request_counter.value >= MAX_PER_WINDOW
  end

  def requests_left
    MAX_PER_WINDOW - request_counter.value
  end

  def reset_time
    ttl = Kredis.redis.ttl(kredis_key) # Ask Redis how long the key has left to live
    (ttl >= 0 ? ttl.seconds.from_now : Time.zone.now).iso8601 # and create a datetime from it
  end

  def kredis_key
    "rate_limiter:#{remote_ip}"
  end

  def request_counter
    # Only set the expires_in when the key is created
    # for the first time. Otherwise expires_in is
    # reset each time the key is accessed.

    if key_exists?
      Kredis.counter(kredis_key)
    else
      Kredis.counter(kredis_key, expires_in: WINDOW_SIZE)
    end
  end

  def key_exists?
    Kredis.redis.exists(kredis_key).positive?
  end

  def remote_ip
    # No need to re-invent logic to calculate the remote IP. It's already
    # available to use in ActionDispatch.

    ActionDispatch::RemoteIp::GetIp.new(@req, false, []).calculate_ip
  end

  def response_normal
    # Give back a normal response after incrementing the counter

    request_counter.increment
    @app.call(@req.env).tap do |_status, headers, _body|
      rate_limit_headers.each { |key, value| headers[key] = value }
    end
  end

  def response_limit_reached
    # We can also just put 429 here but this is more explicit.
    status_code = Rack::Utils::SYMBOL_TO_STATUS_CODE[:too_many_requests]

    [status_code, rate_limit_headers, []]
  end
end
