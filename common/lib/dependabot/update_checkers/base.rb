# frozen_string_literal: true

require "json"
require "dependabot/utils"

module Dependabot
  module UpdateCheckers
    class Base
      attr_reader :dependency, :dependency_files, :credentials,
                  :ignored_versions, :requirements_update_strategy

      def initialize(dependency:, dependency_files:, credentials:,
                     ignored_versions: [], requirements_update_strategy: nil)
        @dependency = dependency
        @dependency_files = dependency_files
        @credentials = credentials
        @requirements_update_strategy = requirements_update_strategy
        @ignored_versions = ignored_versions
      end

      def up_to_date?
        if dependency.appears_in_lockfile?
          version_up_to_date?
        else
          requirements_up_to_date?
        end
      end

      def can_update?(requirements_to_unlock:)
        if dependency.appears_in_lockfile?
          version_can_update?(requirements_to_unlock: requirements_to_unlock)
        else
          # TODO: Handle full unlock updates for dependencies without a lockfile
          return false if requirements_to_unlock == :none

          requirements_can_update?
        end
      end

      def updated_dependencies(requirements_to_unlock:)
        unless can_update?(requirements_to_unlock: requirements_to_unlock)
          return []
        end

        case requirements_to_unlock&.to_sym
        when :none then [updated_dependency_without_unlock]
        when :own then [updated_dependency_with_own_req_unlock]
        when :all then updated_dependencies_after_full_unlock
        else raise "Unknown unlock level '#{requirements_to_unlock}'"
        end
      end

      def latest_version
        raise NotImplementedError
      end

      def latest_resolvable_version
        raise NotImplementedError
      end

      def latest_resolvable_version_with_no_unlock
        raise NotImplementedError
      end

      def updated_requirements
        raise NotImplementedError
      end

      def version_class
        Utils.version_class_for_package_manager(dependency.package_manager)
      end

      def requirement_class
        Utils.requirement_class_for_package_manager(dependency.package_manager)
      end

      # For some langauges, the manifest file may be constructed such that
      # Dependabot has no way to update it (e.g., if it fetches its versions
      # from a web API). This method is overridden in those cases.
      def requirements_unlocked_or_can_be?
        true
      end

      private

      def latest_version_resolvable_with_full_unlock?
        raise NotImplementedError
      end

      def updated_dependency_without_unlock
        Dependency.new(
          name: dependency.name,
          version: latest_resolvable_version_with_no_unlock.to_s,
          requirements: dependency.requirements,
          previous_version: dependency.version,
          previous_requirements: dependency.requirements,
          package_manager: dependency.package_manager
        )
      end

      def updated_dependency_with_own_req_unlock
        Dependency.new(
          name: dependency.name,
          version: latest_resolvable_version.to_s,
          requirements: updated_requirements,
          previous_version: dependency.version,
          previous_requirements: dependency.requirements,
          package_manager: dependency.package_manager
        )
      end

      def updated_dependencies_after_full_unlock
        raise NotImplementedError
      end

      def version_up_to_date?
        return sha1_version_up_to_date? if existing_version_is_sha?

        numeric_version_up_to_date?
      end

      def version_can_update?(requirements_to_unlock:)
        if existing_version_is_sha?
          return sha1_version_can_update?(
            requirements_to_unlock: requirements_to_unlock
          )
        end

        numeric_version_can_update?(
          requirements_to_unlock: requirements_to_unlock
        )
      end

      def existing_version_is_sha?
        return false if version_class.correct?(dependency.version)

        dependency.version.match?(/^[0-9a-f]{6,}$/)
      end

      def sha1_version_up_to_date?
        latest_version&.to_s&.start_with?(dependency.version)
      end

      def sha1_version_can_update?(requirements_to_unlock:)
        return false if sha1_version_up_to_date?

        # All we can do with SHA-1 hashes is check for presence and equality
        case requirements_to_unlock&.to_sym
        when :none
          new_version = latest_resolvable_version_with_no_unlock
          new_version && !new_version.to_s.start_with?(dependency.version)
        when :own
          new_version = latest_resolvable_version
          new_version && !new_version.to_s.start_with?(dependency.version)
        when :all
          latest_version_resolvable_with_full_unlock?
        else raise "Unknown unlock level '#{requirements_to_unlock}'"
        end
      end

      def numeric_version_up_to_date?
        return false unless latest_version

        # If a lockfile isn't out of date and the package has switched to a git
        # source then we'll get a numeric version switching to a git SHA. In
        # this case we treat the verison as up-to-date so that it's ignored.
        return true if latest_version.to_s.match?(/^[0-9a-f]{40}$/)

        latest_version <= version_class.new(dependency.version)
      end

      def numeric_version_can_update?(requirements_to_unlock:)
        return false if numeric_version_up_to_date?

        case requirements_to_unlock&.to_sym
        when :none
          new_version = latest_resolvable_version_with_no_unlock
          new_version && new_version > version_class.new(dependency.version)
        when :own
          new_version = latest_resolvable_version
          new_version && new_version > version_class.new(dependency.version)
        when :all
          latest_version_resolvable_with_full_unlock?
        else raise "Unknown unlock level '#{requirements_to_unlock}'"
        end
      end

      def requirements_up_to_date?
        return true if (updated_requirements - dependency.requirements).none?
        return false unless latest_version
        return false unless version_class.correct?(latest_version.to_s)
        return false unless version_from_requirements

        version_from_requirements >= version_class.new(latest_version.to_s)
      end

      def version_from_requirements
        @version_from_requirements ||=
          dependency.requirements.map { |r| r.fetch(:requirement) }.compact.
          flat_map { |req_str| requirement_class.requirements_array(req_str) }.
          flat_map(&:requirements).
          reject { |req_array| req_array.first.start_with?("<") }.
          map(&:last).
          max
      end

      def requirements_can_update?
        changed_reqs = updated_requirements - dependency.requirements

        return false if changed_reqs.none?

        changed_reqs.none? { |r| r[:requirement] == :unfixable }
      end

      def ignore_reqs
        ignored_versions.map { |req| requirement_class.new(req.split(",")) }
      end
    end
  end
end
