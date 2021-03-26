# frozen_string_literal: true

World Rack::Test::Methods

Before "@api/v1" do
  @api_version = "v1"
end

# FIXME(ezekg) This is super hacky but there's no easy way to disable
#              bullet outside of adding controller filters
Before("@skip/bullet") { Bullet.instance_variable_set :@enable, false }
After("@skip/bullet") { Bullet.instance_variable_set :@enable, true }

Before do
  Bullet.start_request if Bullet.enable?

  ActionMailer::Base.deliveries.clear
  Sidekiq::Worker.clear_all
  StripeHelper.start
  Rails.cache.clear

  @crypt = []
end

After do |scenario|
  Bullet.perform_out_of_channel_notifications if Bullet.enable? && Bullet.notification?
  Bullet.end_request if Bullet.enable?

  StripeHelper.stop

  # Tell Cucumber to quit if a scenario fails
  if scenario.failed?
    Cucumber.wants_to_quit = true

    log JSON.pretty_generate(
      request: {
        url: last_request.url,
        # headers: {
        #   authorization: last_request.get_header('Authorization')
        # },
        body: (JSON.parse(last_request.body.string) rescue nil)
      },
      response: {
        status: last_response.status,
        # headers: last_response.headers,
        body: (JSON.parse(last_response.body) rescue nil)
      }
    )
  end

  # Clear redis cache keys
  begin
    Rails.cache.clear
  rescue => e
    log '[REDIS]', e
  end

  @account = nil
  @token = nil
end
