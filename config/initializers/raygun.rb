# frozen_string_literal: true

Raygun.setup do |config|
  config.api_key = ENV["RAYGUN_API_KEY"]
  config.affected_user_method = :current_bearer
  config.filter_parameters = Rails.application.config.filter_parameters
  config.enable_reporting = Rails.env.production?
  config.logger = Rails.logger
end