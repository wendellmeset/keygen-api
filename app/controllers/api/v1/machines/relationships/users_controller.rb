# frozen_string_literal: true

module Api::V1::Machines::Relationships
  class UsersController < Api::V1::BaseController
    before_action :scope_to_current_account!
    before_action :require_active_subscription!
    before_action :authenticate_with_token!
    before_action :set_machine

    # GET /machines/1/user
    def show
      @user = @machine.user
      authorize @user

      render jsonapi: @user
    end

    private

    def set_machine
      @machine = FindByAliasService.new(current_account.machines, params[:machine_id], aliases: :fingerprint).call
      authorize @machine, :show?

      Keygen::Store::Request.store[:current_resource] = @machine
    end
  end
end
