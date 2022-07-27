# Rails application with rate limiting middleware as published to dev.to

Creating your own middleware in a Rails application is not something a lot of developers do or have to do. But when you want to add custom headers, authentication or some kind of rate limiting, you should definitely consider using middleware. I want to show you how you can implement a small rate limiter using your own middleware.

## Middleware in Rails
Middleware in Rails is actually middleware in Rack. Rack connects a web framework (e.g. Rails) with a web server (e.g. Puma). It is responsible for wrapping http data to present it in a single method call where you can work with requests and responses. That single method call is where you put the middleware logic. You can consider middleware to be the entry and exit of you Rails application.

Each piece of middleware receives the current environment from the previous middleware (if any) and reads and/or changes this environment to pass it on to the next middleware (again, if any).

There is actually already a lot of default middleware in a vanilla Rails application created with `rails new`. You can list that middleware by running `./bin/rails middleware`. For a new Rails 7 application it looks like this:
```
use ActionDispatch::HostAuthorization
use Rack::Sendfile
use ActionDispatch::Static
use ActionDispatch::Executor
use ActionDispatch::ServerTiming
use ActiveSupport::Cache::Strategy::LocalCache::Middleware
use Rack::Runtime
use Rack::MethodOverride
use ActionDispatch::RequestId
use ActionDispatch::RemoteIp
use Sprockets::Rails::QuietAssets
use Rails::Rack::Logger
use ActionDispatch::ShowExceptions
use Sentry::Rails::CaptureExceptions
use WebConsole::Middleware
use ActionDispatch::DebugExceptions
use Sentry::Rails::RescuedExceptionInterceptor
use ActionDispatch::ActionableExceptions
use ActionDispatch::Reloader
use ActionDispatch::Callbacks
use ActiveRecord::Migration::CheckPending
use ActionDispatch::Cookies
use ActionDispatch::Session::CookieStore
use ActionDispatch::Flash
use ActionDispatch::ContentSecurityPolicy::Middleware
use ActionDispatch::PermissionsPolicy::Middleware
use Rack::Head
use Rack::ConditionalGet
use Rack::ETag
use Rack::TempfileReaper
use ActionDispatch::Static
run MyApp::Application.routes
```

Let's look at small piece of default middleware called `ActionDispatch::RequestId` ([source](https://github.com/rails/rails/blob/81c5c9971abe7a42a53ddbfede2683081a67e9d1/actionpack/lib/action_dispatch/middleware/request_id.rb)). It already contains a good explaination of the inner workings in the comments of that file. 

```ruby
# https://github.com/rails/rails/blob/81c5c9971abe7a42a53ddbfede2683081a67e9d1/actionpack/lib/action_dispatch/middleware/request_id.rb

require "securerandom"
require "active_support/core_ext/string/access"

module ActionDispatch
  # Makes a unique request id available to the +action_dispatch.request_id+ env variable (which is then accessible
  # through ActionDispatch::Request#request_id or the alias ActionDispatch::Request#uuid) and sends
  # the same id to the client via the X-Request-Id header.
  #
  # The unique request id is either based on the X-Request-Id header in the request, which would typically be generated
  # by a firewall, load balancer, or the web server, or, if this header is not available, a random uuid. If the
  # header is accepted from the outside world, we sanitize it to a max of 255 chars and alphanumeric and dashes only.
  #
  # The unique request id can be used to trace a request end-to-end and would typically end up being part of log files
  # from multiple pieces of the stack.
  class RequestId
    def initialize(app, header:)
      @app = app
      @header = header
    end

    def call(env)
      req = ActionDispatch::Request.new env
      req.request_id = make_request_id(req.headers[@header])
      @app.call(env).tap { |_status, headers, _body| headers[@header] = req.request_id }
    end

    private
      def make_request_id(request_id)
        if request_id.presence
          request_id.gsub(/[^\w\-@]/, "").first(255)
        else
          internal_request_id
        end
      end

      def internal_request_id
        SecureRandom.uuid
      end
  end
end
```

The methods `initialize` and `call` are the key methods. The `initialize` method is called only once at booting the app and can be used to configure the middleware and set up data that is shared with all requests. The most important part is the `call` method definition. It is called at every request a client makes to a Rails app.  The `call` method receives the current Rack environment as Ruby hash and should return a three element array with the status code, response headers and optionally a body. That array is generated by running `@app.call(env)`. Of the two methods, you'll probably work most of the time with `call`.

In the `RequestId` middleware above, the environment (`env`) is changed by adding a header with a request id. That id is determined in the private methods of the middleware class. The header name is taken from the `header` keyword argument in `initalize`. This makes sense: the name of the header doesn't change during the app lifetime but the contents of the header do change each request. That's why the header name is set in `initalize` (runs once at boot time) and the value is set in `call` (runs each new request).

## Our own middleware

Now that we understand a little more about middleware, let's create our own. We will create middleware that implements a simple rate limiter using [Kredis](https://github.com/rails/kredis). Kredis is a nice wrapper around Redis. Other than that, I assume you have some basic knowledge of Rails.

### Basic setup
Make sure you have a working Redis server available. Run `redis-cli` in your shell to check if Redis is running. Something like `127.0.0.1:6379>` should pop up.

Start by creating a new Rails app and add the Kredis gem.
```bash
$ rails new myratelimiter
$ cd myratelimiter
$ ./bin/bundle add kredis
$ ./bin/rails kredis:install
```

Check `config/redis/shared.yml` to make sure the configuration matches your Redis server. When you have a default Redis setup you probably don't have to change anything.

We need something to request from our Rails application so create a controller and model with `./bin/rails g scaffold User name email` and run `.bin/rails db:migrate`.

Create five users by running `5.times {|i| User.create(name: "Name #{i}", email: "user#{i}@example.com")}` in the Rails console.

Start the Rails server and run `curl http://localhost:3000/users.json`. You should see some json containing the five users.

### Rate limiter 
We have a basic api Rails app in place that shows users through `/users.json`. The problem is that consumers of our api can keep on sending requests so it's time to implement rate limiting. 

The requirements of our rate limiter are simple for the sake of simplicity: 
* the consumer of the api cannot send more than 50 requests per 5 minutes
* the consumer receives an http status `429 - Too many requests` when the limit is reached
* the server **always** responds with 3 headers:
  * Rate-Limit-Reached: a boolean which tells the consumer if the rate limit is reached
  * Rate-Limit-Requests-Left: a number which tells how many requests are left in the current time window
  * Rate-Limit-Requests-Reset: a datetime which tells when the rate limiter will reset

Let's start with a few tests for the first two requirements:
```ruby
# test/controllers/users_controller_test.rb
require 'test_helper'

class UsersControllerTest < ActionDispatch::IntegrationTest
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
end
```

If you run the test suite you'll see that the second tests fails. Of course that's correct since we haven't implemented the rate limiter yet so let's go ahead with that.

Create `lib/middleware/rate_limiter.rb` with this class:
```ruby
# lib/middleware/rate_limiter.rb - first draft
class RateLimiter
  def initialize(app)
    @app = app
  end

  def call(env)
    @app.call(env)
  end
end
```

Add this middleware to your app in `config/application.rb`:
```ruby
...
require_relative '../lib/middleware/rate_limiter'
...
module Myratelimiter
  class Application < Rails::Application
    ...
    config.middleware.insert_before 0, RateLimiter
  end
end
```

That's it. You now have your own middleware in place. It doesn't do a lot at this point and running the test suite still yields the same failing tests. 
Time to implement the first two requirements. I'm going to show you the complete middleware class for those requirements and go through it step by step.

```ruby
# lib/middleware/rate_limiter.rb - second draft
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

  def rate_limited?
    request_counter.value >= MAX_PER_WINDOW
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
    @app.call(@req.env)
  end

  def response_limit_reached
    # We can also just put 429 here but this is more explicit.
    status_code = Rack::Utils::SYMBOL_TO_STATUS_CODE[:too_many_requests]

    [status_code, {}, []]
  end
end

```

If you run the test suite now, it will pass. If you want to test it yourself, set `MAX_PER_WINDOW` to 3 and run `curl -v http://localhost:3000/users.json` four times. The first three times the server responds as usual. The fourth time it returns an empty body with status code 429 - Too many requests.

What's happening in our newly created middleware? On each request the method `call` is called where an `ActionDispatch::Request` class is instantiated. With that object we can work easier with the data in `env`. Then we check if the rate limit is reached and return an appropriate response.

In `rate_limited?` the method `request_counter` is called which brings us to the part where Kredis is used. We use Kredis to initialize a counter in Redis. Kredis 'instantiates' the value from Redis. In other words, when you call `Kredis.counter("mykey")` we have an object that points to a Redis value under `mykey`. On that object we can call `#increment` which increments the current value in Redis. As you can see we check if the Redis key exists so that we can decide to use the call with `expires_in`. Each time you call `#counter` with `expires_in`, the expire timer resets. We don't want that because then the key will never expire. Checkout the [Kredis docs](https://github.com/rails/kredis) for more information about Kredis.

We need some way to identify the consumer (or visitor if you will). A session is not an option since we don't have access to it yet and it's easy to circumvent by simple deleting cookies client side. Maybe an IP address? It's not really easy to spoof and you have to go through greater lengths to change the IP each n requests. On the other hand, a public IP is often shared amongst many users behind some router. For now, we go with an IP address but in the real world you'll probably identify a user with a token. In the method `kredis_key` the key is composed from `remote_ip`. In `remote_ip` we use logic that Rails already provides from ActionDispatch.

If the rate limit is not reached, `response_normal` is called where the request counter in Redis is incremented and the control is given back to Rails with `@app.call(@req.env)`. But if the rate limit is reached, `response_limit_reached` is called. In that method we return a three element array containing the http status code, extra headers and a body. The last two are empty since the status code 'too many requests' is enough to inform the consumer the rate limit is reached.

You now have a working rate limiter as middleware. It might be too basic for a real world application but it does the job.

### Extra headers
We still need to fulfill the third requirement: three headers containing information about the rate limiter. 

Let's start with the first header called `Rate-Limit-Reached`. First we write a new test:

```ruby
class UsersControllerTest < ActionDispatch::IntegrationTest
  ...
  test 'should return correct Rate-Limit-Reached header' do
    get users_url

    # You may be tempted to use `refute` but we want to make sure it really is false
    # instead of falsey like nil.
    assert_equal false, response.headers['Rate-Limit-Reached']

    50.times { get users_url } # Trigger rate limiter
    assert_equal true, response.headers['Rate-Limit-Reached']
  end
  ...
end
```

Run the test suite and it should fail. Add/replace the following methods:

```ruby
class RateLimiter
  ...
  def rate_limit_headers
    {
      'Rate-Limit-Reached' => rate_limited?
    }
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
  ...
end
```

Now the test suite passes and we have implemented the first header requirement. 

On to the next header called `Rate-Limit-Requests-Left`. Append the following to the test suite:

```ruby
class UsersControllerTest < ActionDispatch::IntegrationTest
  ...
  test 'should return correct Rate-Limit-Left header' do
    get users_url

    assert_equal 49, response.headers['Rate-Limit-Left']

    50.times { get users_url } # Trigger rate limiter
    assert_equal 0, response.headers['Rate-Limit-Left']
  end
  ...
end
```

Run the test suite again to make sure it fails and add/replace the following methods:
```ruby
class RateLimiter
  ...
  def rate_limit_headers
    {
      'Rate-Limit-Reached' => rate_limited?,
      'Rate-Limit-Left' => requests_left
    }
  end

  def requests_left
    MAX_PER_WINDOW - request_counter.value
  end
  ...
end
```

This will yield a passing test suite. We now have implemented the first two required headers. 

Let's finish up with the third header called `Rate-Limit-Requests-Reset`. Again we start with a new test:

```ruby
class UsersControllerTest < ActionDispatch::IntegrationTest
  ...
  test 'should return correct Rate-Limit-Reset header' do
    get users_url

    seconds_left = Time.parse(response.headers['Rate-Limit-Reset']) - Time.now.utc
    assert seconds_left.between?(1.minute - 5.seconds, 1.minute)

    50.times { get users_url } # Trigger rate limiter
    seconds_left = Time.parse(response.headers['Rate-Limit-Reset']) - Time.now.utc
    assert seconds_left.between?(1.minute - 5.seconds, 1.minute)
  end
  ...
end
```

And the logic to add/replace in the middleware:
```ruby
class RateLimiter
  ...
  def rate_limit_headers
    {
      'Rate-Limit-Reached' => rate_limited?,
      'Rate-Limit-Left' => requests_left,
      'Rate-Limit-Reset' => reset_time
    }
  end

  def reset_time
    ttl = Kredis.redis.ttl(kredis_key) # Ask Redis how long the key has left to live
    (ttl >= 0 ? ttl.seconds.from_now : Time.zone.now).iso8601 # Create a datetime from TTL
  end
  ...
end
```

Run the test suite again, all tests should pass.

## Wrapping it up

And now you have created some middleware to implement a rate limiter with a test suite. You can find the source of the above Rails application [here](https://github.com/LoranKloeze/rails_rate_limiter_middleware).

The main purpose of this article was to show you how to develop middleware and not how to develop the world's most sophisticated rate limiter. But I hope it gave you some inspiration!

## Notes
* The test suite is kind of slow because we run the `n.times { get users_url }` blocks a lot... I'm going to let you figure out a refactor of the test suite to increase the performance. A small pointer: think about running two response cycles (normal and abnormal) and caching the results so each test can use the cached responses.
* There is one important case not tested in the suite and that is the moment the request limit has been reset. Normally you can use `travel` but the TTL is set in Redis and not in the Rails app. You can refactor the middleware to accept a configuration value for the window size and set it to a few seconds so that it can be tested.
