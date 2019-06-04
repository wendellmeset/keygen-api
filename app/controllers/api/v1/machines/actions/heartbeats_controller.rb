module Api::V1::Machines::Actions
  class HeartbeatsController < Api::V1::BaseController
    before_action :scope_to_current_account!
    before_action :require_active_subscription!
    before_action :authenticate_with_token!
    before_action :set_machine

    # POST /machines/1/reset-heartbeat
    def reset_heartbeat
      authorize @machine

      if !@machine.update(last_heartbeat_at: nil)
        render_unprocessable_resource(@machine) and return
      end

      CreateWebhookEventService.new(
        event: "machine.heartbeat.reset",
        account: current_account,
        resource: @machine
      ).execute

      render jsonapi: @machine
    end

    # POST /machines/1/ping-heartbeat
    def ping_heartbeat
      authorize @machine

      if @machine.heartbeat_dead?
        render_unprocessable_entity(detail: "is dead", source: { pointer: "/data/attributes/heartbeatStatus" }) and return
      end

      if !@machine.update(last_heartbeat_at: Time.current)
        render_unprocessable_resource(@machine) and return
      end

      CreateWebhookEventService.new(
        event: "machine.heartbeat.ping",
        account: current_account,
        resource: @machine
      ).execute

      # Queue up heartbeat worker which will handle deactivating dead machines
      MachineHeartbeatWorker.perform_in(
        Machine::HEARTBEAT_TTL + Machine::HEARTBEAT_DRIFT,
        @machine.id
      )

      render jsonapi: @machine
    end

    private

    def set_machine
      @machine =
        if params[:id] =~ UUID_REGEX
          current_account.machines.find_by id: params[:id]
        else
          current_account.machines.find_by fingerprint: params[:id]
        end

      raise Keygen::Error::NotFoundError.new(model: Machine.name, id: params[:id]) if @machine.nil?
    end
  end
end
