# frozen_string_literal: true

class LicenseValidationService < BaseService

  def initialize(license:, scope: nil, skip_touch: false)
    @account    = license&.account
    @product    = license&.product
    @license    = license
    @scope      = scope
    @skip_touch = skip_touch
    @touches    = {
      last_validated_at: Time.current,
    }
  end

  def call
    res = validate!
    touch! unless skip_touch?
    res
  end

  private

  attr_reader :account,
              :product,
              :license,
              :scope,
              :touches

  def skip_touch? = !!@skip_touch

  def validate!
    return [false, "does not exist", :NOT_FOUND] if license.nil?

    # Check if license's user has been banned
    return [false, "is banned", :BANNED] if
      license.banned?

    # Check if license is suspended
    return [false, "is suspended", :SUSPENDED] if license.suspended?

    # When revoking access, first check if license is expired (i.e. higher precedence)
    return [false, "is expired", :EXPIRED] if
      license.revoke_access? &&
      license.expired?

    # Check if license is overdue for check in
    return [false, "is overdue for check in", :OVERDUE] if license.check_in_overdue?

    # Scope validations (quick validation skips this by setting explicitly to false)
    if scope != false
      # Check against environment scope requirements
      if scope.present? && scope.key?(:environment)
        return [false, "environment scope does not match", :ENVIRONMENT_SCOPE_MISMATCH] unless
          license.environment&.code == scope[:environment] ||
          license.environment&.id == scope[:environment]
      else
        return [false, "environment scope is required", :ENVIRONMENT_SCOPE_REQUIRED] if
          license.policy.require_environment_scope?
      end

      # Check against product scope requirements
      if scope.present? && scope.key?(:product)
        return [false, "product scope does not match", :PRODUCT_SCOPE_MISMATCH] if license.product.id != scope[:product]
      else
        return [false, "product scope is required", :PRODUCT_SCOPE_REQUIRED] if license.policy.require_product_scope?
      end

      # Check against policy scope requirements
      if scope.present? && scope.key?(:policy)
        return [false, "policy scope does not match", :POLICY_SCOPE_MISMATCH] if license.policy.id != scope[:policy]
      else
        return [false, "policy scope is required", :POLICY_SCOPE_REQUIRED] if license.policy.require_policy_scope?
      end

      # Check against :user scope requirements
      if scope.present? && scope.key?(:user)
        return [false, "user scope does not match", :USER_SCOPE_MISMATCH] unless
          license.user&.email == scope[:user] ||
          license.user&.id == scope[:user]
      else
        return [false, "user scope is required", :USER_SCOPE_REQUIRED] if
          license.policy.require_user_scope?
      end

      # Check against entitlement scope requirements
      if scope.present? && scope.key?(:entitlements)
        entitlements = scope[:entitlements].uniq

        return [false, "entitlements scope is empty", :ENTITLEMENTS_SCOPE_EMPTY] if
          entitlements.empty?

        return [false, "is missing one or more required entitlements", :ENTITLEMENTS_MISSING] if
          license.entitlements.where(code: entitlements).count != entitlements.size
      end

      # Check against machine scope requirements
      if scope.present? && scope.key?(:machine)
        case
        when !license.policy.floating? && license.machines_count == 0
          return [false, "machine is not activated (has no associated machine)", :NO_MACHINE]
        when license.policy.floating? && license.machines_count == 0
          return [false, "machine is not activated (has no associated machines)", :NO_MACHINES]
        else
          machine = license.machines.find_by(id: scope[:machine])

          return [false, "machine is not activated (does not match any associated machines)", :MACHINE_SCOPE_MISMATCH] unless
            machine.present?

          return [false, 'machine heartbeat is required', :HEARTBEAT_NOT_STARTED] if
            license.policy.require_heartbeat? &&
            machine.heartbeat_not_started?

          return [false, "machine heartbeat is dead", :HEARTBEAT_DEAD] if
            machine.dead?
        end
      else
        return [false, "machine scope is required", :MACHINE_SCOPE_REQUIRED] if license.policy.require_machine_scope?
      end

      # Check against fingerprint scope requirements
      if scope.present? && (scope.key?(:fingerprint) || scope.key?(:fingerprints))
        fingerprints = Array(scope[:fingerprint] || scope[:fingerprints])
                         .compact
                         .uniq

        return [false, "fingerprint scope is empty", :FINGERPRINT_SCOPE_EMPTY] if
          fingerprints.empty?

        case
        when !license.policy.floating? && license.machines_count == 0
          return [false, "fingerprint is not activated (has no associated machine)", :NO_MACHINE]
        when license.policy.floating? && license.machines_count == 0
          return [false, "fingerprint is not activated (has no associated machines)", :NO_MACHINES]
        else
          return [false, 'machine heartbeat is dead', :HEARTBEAT_DEAD] if
            license.machines.dead.with_fingerprint(fingerprints).count == fingerprints.size

          machines = license.machines.with_fingerprint(fingerprints)
                                     .alive

          case
          when fingerprints.size > 1 && license.policy.fingerprint_match_most?
            return [false, "one or more fingerprint is not activated (does not match enough associated machines)", :FINGERPRINT_SCOPE_MISMATCH] if
              machines.count < (fingerprints.size / 2.0).ceil
          when fingerprints.size > 1 && license.policy.fingerprint_match_two?
            return [false, "one or more fingerprint is not activated (does not match at least 2 associated machines)", :FINGERPRINT_SCOPE_MISMATCH] if
              machines.count < 2
          when fingerprints.size > 1 && license.policy.fingerprint_match_all?
            return [false, "one or more fingerprint is not activated (does not match all associated machines)", :FINGERPRINT_SCOPE_MISMATCH] if
              machines.count < fingerprints.size
          when fingerprints.size > 1 && license.policy.fingerprint_match_any?
            return [false, "one or more fingerprint is not activated (does not match any associated machines)", :FINGERPRINT_SCOPE_MISMATCH] if
              machines.empty?
          else
            return [false, "fingerprint is not activated (does not match any associated machines)", :FINGERPRINT_SCOPE_MISMATCH] if
              machines.empty?
          end

          return [false, 'machine heartbeat is required', :HEARTBEAT_NOT_STARTED] if
            license.policy.require_heartbeat? &&
            machines.any?(&:not_started?)
        end
      else
        return [false, "fingerprint scope is required", :FINGERPRINT_SCOPE_REQUIRED] if license.policy.require_fingerprint_scope?
      end

      # Check against component scope requirements
      if scope.present? && scope.key?(:components)
        unless scope.key?(:fingerprint)
          # Matching on components is done per-machine so a singular
          # fingerprint is required
          return [false, "fingerprint scope is required when using the components scope", :FINGERPRINT_SCOPE_REQUIRED]
        end

        fingerprints = scope[:components].compact
                                         .uniq

        return [false, "components scope is empty", :COMPONENTS_SCOPE_EMPTY] if
          fingerprints.empty?

        # We can expect the machine to exist since the :fingerprint scope
        # will have been validated beforehand
        machine    = license.machines.find_by(fingerprint: scope[:fingerprint])
        components = machine.components.with_fingerprint(fingerprints)

        case
        when license.policy.fingerprint_match_most?
          return [false, "one or more component is not activated (does not match enough associated components)", :COMPONENTS_SCOPE_MISMATCH] if
            components.count < (fingerprints.size / 2.0).ceil
        when license.policy.fingerprint_match_two?
          return [false, "one or more component is not activated (does not match at least 2 associated components)", :COMPONENTS_SCOPE_MISMATCH] if
            components.count < 2
        when license.policy.fingerprint_match_all?
          return [false, "one or more component is not activated (does not match all associated components)", :COMPONENTS_SCOPE_MISMATCH] if
            components.count < fingerprints.size
        else
          return [false, "one or more component is not activated (does not match any associated components)", :COMPONENTS_SCOPE_MISMATCH] if
            components.empty?
        end
      else
        return [false, "components scope is required", :COMPONENTS_SCOPE_REQUIRED] if license.policy.require_components_scope?
      end

      # Check against checksum scope
      if scope.present? && scope.key?(:checksum)
        checksum = scope[:checksum]
        artifact = product.release_artifacts.with_checksum(checksum)
                                            .for_license(license)
                                            .order_by_version
                                            .take

        if artifact.nil?
          return [false, "checksum scope is not valid (does not match any accessible artifacts)", :CHECKSUM_SCOPE_MISMATCH]
        end

        touches[:last_validated_checksum] = checksum
        touches[:last_validated_version]  = artifact.version
      else
        return [false, "checksum scope is required", :CHECKSUM_SCOPE_REQUIRED] if license.policy.require_checksum_scope?
      end

      # Check against version scope
      if scope.present? && scope.key?(:version)
        version = scope[:version]
        release = product.releases.with_version(version)
                                  .for_license(license)
                                  .take

        if release.nil?
          return [false, "version scope is not valid (does not match any accessible releases)", :VERSION_SCOPE_MISMATCH]
        end

        touches[:last_validated_version] = release.version
      else
        return [false, "version scope is required", :VERSION_SCOPE_REQUIRED] if license.policy.require_version_scope?
      end
    end

    # Check if license policy is strict, e.g. enforces reporting of machine usage (and exit early if not strict).
    if !license.policy.strict?
      # Check if license is expired after checking machine requirements.
      return [license.allow_access? || license.maintain_access?, "is expired", :EXPIRED] if
        license.expired?

      return [true, "is valid", :VALID]
    end

    # Check if license policy allows floating and if not, should have single activation
    return [false, "must have exactly 1 associated machine", :NO_MACHINE] if
      !license.policy.floating? && license.machines_count == 0

    # When not floating, license's machine count should not surpass 1
    if !license.policy.floating? && license.machines_count > 1
      allow_overage = license.always_allow_overage? ||
                      (license.allow_2x_overage? && license.machines_count == 2)

      return [allow_overage, "has too many associated machines", :TOO_MANY_MACHINES]
    end

    # When floating, license should have at least 1 activation
    return [false, "must have at least 1 associated machine", :NO_MACHINES] if
      license.policy.floating? && license.machines_count == 0

    # When floating, license's machine count should not surpass what policy allows
    if license.floating? && !license.max_machines.nil? && license.machines_count > license.max_machines
      allow_overage = license.always_allow_overage? ||
                      (license.allow_1_25x_overage? && license.machines_count <= license.max_machines * 1.25) ||
                      (license.allow_1_5x_overage? && license.machines_count <= license.max_machines * 1.5) ||
                      (license.allow_2x_overage? && license.machines_count <= license.max_machines * 2)

      return [allow_overage, "has too many associated machines", :TOO_MANY_MACHINES]
    end

    # Check if license has exceeded its CPU core limit
    if !license.max_cores.nil? && !license.machines_core_count.nil? && license.machines_core_count > license.max_cores
      allow_overage = license.always_allow_overage? ||
                      (license.allow_1_25x_overage? && license.machines_core_count <= license.max_cores * 1.25) ||
                      (license.allow_1_5x_overage? && license.machines_core_count <= license.max_cores * 1.5) ||
                      (license.allow_2x_overage? && license.machines_core_count <= license.max_cores * 2)

      return [allow_overage, "has too many associated machine cores", :TOO_MANY_CORES]
    end

    # Check if license has exceeded its process limit
    if license.max_processes.present?
      process_count = 0
      process_limit = 0

      case
      when license.lease_per_machine? && scope.present? && (scope.key?(:fingerprint) || scope.key?(:fingerprints))
        machine = license.machines.alive.find_by(
          fingerprint: Array(scope[:fingerprint] || scope[:fingerprints])
                         .compact
                         .uniq,
        )

        process_count = machine.processes.count
        process_limit = machine.max_processes
      when license.lease_per_machine? && scope.present? && scope.key?(:machine)
        machine = license.machines.alive.find_by(id: scope[:machine])

        process_count = machine.processes.count
        process_limit = machine.max_processes
      when license.lease_per_license?
        process_count = license.processes.count
        process_limit = license.max_processes
      end

      allow_overage = license.always_allow_overage? ||
                      (license.allow_1_25x_overage? && process_count <= process_limit * 1.25) ||
                      (license.allow_1_5x_overage? && process_count <= process_limit * 1.5) ||
                      (license.allow_2x_overage? && process_count <= process_limit * 2)

      return [allow_overage, "has too many associated processes", :TOO_MANY_PROCESSES] if
        process_count > process_limit
    end

    # Check if license is expired after checking machine requirements.
    return [license.allow_access? || license.maintain_access?, "is expired", :EXPIRED] if
      license.expired?

    # All good
    return [true, "is valid", :VALID]
  end

  # TODO(ezekg) Move to a background job so we can read from replicas for validations.
  def touch!
    return if
      skip_touch? || touches.empty?

    # We're going to attempt to update the license's last validated timestamp and
    # other metadata, but if there's a concurrent update then we'll skip. This
    # sheds load when a license is validated too often, e.g. in an infinite
    # loop or via a high number of concurrent processes.
    license&.with_lock 'FOR UPDATE SKIP LOCKED' do
      license.update!(**touches)
    end
  rescue ActiveRecord::LockWaitTimeout, # For NOWAIT lock wait timeout error
         ActiveRecord::RecordNotFound   # SKIP LOCKED raises not found
    # noop
  rescue => e
    Keygen.logger.exception(e)

    raise e
  end
end
