require "httparty"

class WebhookWorker
  ACCEPTABLE_CODES = (200..299).freeze

  include Sidekiq::Worker
  include Sidekiq::Status::Worker
  include Signable

  sidekiq_options queue: :webhooks, retry: 15

  def perform(account_id, event_id, endpoint_id, payload)
    account = Account.find account_id
    endpoint = account.webhook_endpoints.find endpoint_id
    event = account.webhook_events.find event_id

    res = Request.post(endpoint.url, {
      headers: {
        "Content-Type" => "application/json",
        "X-Signature" => sign(
          key: account.private_key,
          data: payload
        )
      },
      body: payload
    })

    # TODO(ezekg) Remove this error handling after we know everything is working
    begin
      event.update(
        last_response_code: res.code,
        last_response_body: res.body
      )
    rescue => e
      Raygun.track_exception e
    end

    if !ACCEPTABLE_CODES.include?(res.code)
      raise FailedRequestError
    end
  rescue OpenSSL::SSL::SSLError # Endpoint's SSL certificate is not showing as valid
    event.update(
      last_response_code: nil,
      last_response_body: 'SSL_ERROR'
    )
  rescue Net::ReadTimeout, Net::OpenTimeout # Our request to the endpoint timed out
    event.update(
      last_response_code: nil,
      last_response_body: 'REQ_TIMEOUT'
    )
  rescue SocketError # Stop sending requests if DNS is no longer working for endpoint
    event.update(
      last_response_code: nil,
      last_response_body: 'DNS_ERROR'
    )
  end

  class FailedRequestError < StandardError; end
  class Request
    include HTTParty
  end
end
