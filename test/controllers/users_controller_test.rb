# frozen_string_literal: true

require 'test_helper'

class UsersControllerTest < ActionDispatch::IntegrationTest
  EXPECTED_MAX_PER_WINDOW = 50
  EXPECTED_WINDOW_SIZE = 1.minute

  setup do
    Kredis.redis.flushall
    @user = users(:one)
  end

  test 'should not rate limit normal use' do
    49.times do
      get users_url
      assert_response :success
    end
  end

  test 'should rate limit abnormal use' do
    50.times do
      get users_url
      assert_response :success
    end

    get users_url
    assert_response :too_many_requests
  end

  test 'should return correct Rate-Limit-Reached header' do
    get users_url

    # You may be tempted to use refute but we want to make sure it really is false
    # instead of falsey like nil.
    assert_equal false, response.headers['Rate-Limit-Reached']

    50.times { get users_url } # Trigger rate limiter
    assert_equal true, response.headers['Rate-Limit-Reached']
  end

  test 'should return correct Rate-Limit-Left header' do
    get users_url
    assert_equal 49, response.headers['Rate-Limit-Left']

    50.times { get users_url } # Trigger rate limiter
    assert_equal 0, response.headers['Rate-Limit-Left']
  end

  test 'should return correct Rate-Limit-Reset header' do
    get users_url

    seconds_left = Time.parse(response.headers['Rate-Limit-Reset']) - Time.now.utc
    assert seconds_left.between?(1.minute - 5.seconds, 1.minute)

    50.times { get users_url } # Trigger rate limiter
    seconds_left = Time.parse(response.headers['Rate-Limit-Reset']) - Time.now.utc
    assert seconds_left.between?(1.minute - 5.seconds, 1.minute)
  end
end
