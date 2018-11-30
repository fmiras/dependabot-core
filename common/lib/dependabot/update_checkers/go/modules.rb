# frozen_string_literal: true

require "toml-rb"
require "dependabot/update_checkers/base"
require "dependabot/shared_helpers"
require "dependabot/errors"
require "dependabot/utils/go/version"
require "dependabot/utils/go/shared_helper"

module Dependabot
  module UpdateCheckers
    module Go
      class Modules < Dependabot::UpdateCheckers::Base
        def latest_resolvable_version
          @latest_resolvable_version ||=
            version_class.new(find_latest_resolvable_version.gsub(/^v/, ""))
        end

        # This is currently used to short-circuit latest_resolvable_version,
        # with the assumption that it'll be quicker than checking
        # resolvability. As this is quite quick in Go anyway, we just alias.
        def latest_version
          latest_resolvable_version
        end

        def latest_resolvable_version_with_no_unlock
          # Irrelevant, since Go modules uses a single dependency file
          nil
        end

        def updated_requirements
          dependency.requirements.map do |req|
            req.merge(requirement: latest_version)
          end
        end

        private

        def find_latest_resolvable_version
          SharedHelpers.in_a_temporary_directory do
            SharedHelpers.with_git_configured(credentials: credentials) do
              File.write("go.mod", go_mod.content)

              SharedHelpers.run_helper_subprocess(
                command: "GO111MODULE=on #{Utils::Go::SharedHelper.path}",
                function: "getUpdatedVersion",
                args: {
                  dependency: {
                    name: dependency.name,
                    version: "v" + dependency.version,
                    indirect: dependency.requirements.empty?
                  }
                }
              )
            end
          end
        end

        def latest_version_resolvable_with_full_unlock?
          # Full unlock checks aren't implemented for Go (yet)
          false
        end

        def updated_dependencies_after_full_unlock
          raise NotImplementedError
        end

        # Override the base class's check for whether this is a git dependency,
        # since not all dep git dependencies have a SHA version (sometimes their
        # version is the tag)
        def existing_version_is_sha?
          git_dependency?
        end

        def library?
          dependency_files.none? { |f| f.type == "package_main" }
        end

        def version_from_tag(tag)
          # To compare with the current version we either use the commit SHA
          # (if that's what the parser picked up) of the tag name.
          if dependency.version&.match?(/^[0-9a-f]{40}$/)
            return tag&.fetch(:commit_sha)
          end

          tag&.fetch(:tag)
        end

        def git_dependency?
          git_commit_checker.git_dependency?
        end

        def default_source
          { type: "default", source: dependency.name }
        end

        def go_mod
          @go_mod ||= dependency_files.find { |f| f.name == "go.mod" }
        end

        def git_commit_checker
          @git_commit_checker ||=
            GitCommitChecker.new(
              dependency: dependency,
              credentials: credentials,
              ignored_versions: ignored_versions
            )
        end
      end
    end
  end
end
