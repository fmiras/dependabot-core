# frozen_string_literal: true

require "dependabot/file_updaters/base"
require "dependabot/shared_helpers"

module Dependabot
  module FileUpdaters
    module Python
      class Pip < Dependabot::FileUpdaters::Base
        require_relative "pip/pipfile_file_updater"
        require_relative "pip/pip_compile_file_updater"
        require_relative "pip/poetry_file_updater"
        require_relative "pip/requirement_file_updater"

        def self.updated_files_regex
          [
            /^Pipfile$/,
            /^Pipfile\.lock$/,
            /.*\.txt$/,
            /.*\.in$/,
            /^setup\.py$/,
            /^pyproject\.toml$/,
            /^pyproject\.lock$/
          ]
        end

        def updated_dependency_files
          updated_files =
            case resolver_type
            when :pipfile then updated_pipfile_based_files
            when :poetry then updated_poetry_based_files
            when :pip_compile then updated_pip_compile_based_files
            when :requirements then updated_requirement_based_files
            else raise "Unexpected resolver type: #{resolver_type}"
            end

          if updated_files.none? ||
             updated_files.sort_by(&:name) == dependency_files.sort_by(&:name)
            raise "No files have changed!"
          end

          updated_files
        end

        private

        def resolver_type
          reqs = dependencies.flat_map(&:requirements)
          req_files = reqs.map { |r| r.fetch(:file) }

          # If there are no requirements then this is a sub-dependency. It
          # must come from one of Pipenv, Poetry or pip-tools, and can't come
          # from the first two unless they have a lockfile.
          return subdependency_resolver if reqs.none?

          # Otherwise, this is a top-level dependency, and we can figure out
          # which resolver to use based on the filename of its requirements
          return :pipfile if req_files.any? { |f| f == "Pipfile" }
          return :poetry if req_files.any? { |f| f == "pyproject.toml" }
          return :pip_compile if req_files.any? { |f| f.end_with?(".in") }

          # Finally, we should only ever be updating a requirements.txt file if
          # some requirements have changed. Otherwise, this must be a case where
          # we have a requirements.txt *and* some other resolver of which the
          # dependency is a sub-dependency.
          changed_reqs = reqs - dependencies.flat_map(&:previous_requirements)
          changed_reqs.none? ? subdependency_resolver : :requirements
        end

        def subdependency_resolver
          return :pipfile if pipfile_lock
          return :poetry if poetry_lock || pyproject_lock
          return :pip_compile if pip_compile_files.any?

          raise "Claimed to be a sub-dependency, but no lockfile exists!"
        end

        def updated_pipfile_based_files
          PipfileFileUpdater.new(
            dependencies: dependencies,
            dependency_files: dependency_files,
            credentials: credentials
          ).updated_dependency_files
        end

        def updated_poetry_based_files
          PoetryFileUpdater.new(
            dependencies: dependencies,
            dependency_files: dependency_files,
            credentials: credentials
          ).updated_dependency_files
        end

        def updated_pip_compile_based_files
          PipCompileFileUpdater.new(
            dependencies: dependencies,
            dependency_files: dependency_files,
            credentials: credentials
          ).updated_dependency_files
        end

        def updated_requirement_based_files
          RequirementFileUpdater.new(
            dependencies: dependencies,
            dependency_files: dependency_files,
            credentials: credentials
          ).updated_dependency_files
        end

        def check_required_files
          filenames = dependency_files.map(&:name)
          return if filenames.any? { |name| name.end_with?(".txt", ".in") }
          return if pipfile
          return if pyproject
          return if get_original_file("setup.py")

          raise "No requirements.txt or setup.py!"
        end

        def pipfile
          @pipfile ||= get_original_file("Pipfile")
        end

        def pipfile_lock
          @pipfile_lock ||= get_original_file("Pipfile.lock")
        end

        def pyproject
          @pyproject ||= get_original_file("pyproject.toml")
        end

        def pyproject_lock
          @pyproject_lock ||= get_original_file("pyproject.lock")
        end

        def poetry_lock
          @poetry_lock ||= get_original_file("poetry.lock")
        end

        def pip_compile_files
          @pip_compile_files ||=
            dependency_files.select { |f| f.name.end_with?(".in") }
        end
      end
    end
  end
end
