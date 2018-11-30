# frozen_string_literal: true

require "excon"

require "dependabot/clients/github_with_retries"
require "dependabot/clients/gitlab"
require "dependabot/clients/bitbucket"
require "dependabot/shared_helpers"
require "dependabot/metadata_finders/base"

module Dependabot
  module MetadataFinders
    class Base
      class ChangelogFinder
        require_relative "changelog_pruner"
        require_relative "commits_finder"

        # Earlier entries are preferred
        CHANGELOG_NAMES = %w(changelog history news changes release).freeze

        attr_reader :source, :dependency, :credentials

        def initialize(source:, dependency:, credentials:)
          @source = source
          @dependency = dependency
          @credentials = credentials
        end

        def changelog_url
          changelog&.html_url
        end

        def changelog_text
          return unless full_changelog_text

          ChangelogPruner.new(
            dependency: dependency,
            changelog_text: full_changelog_text
          ).pruned_text
        end

        def upgrade_guide_url
          upgrade_guide&.html_url
        end

        def upgrade_guide_text
          return unless upgrade_guide

          @upgrade_guide_text ||= fetch_file_text(upgrade_guide)
        end

        private

        # rubocop:disable Metrics/CyclomaticComplexity
        # rubocop:disable Metrics/PerceivedComplexity
        def changelog
          return unless source

          # Changelog won't be relevant for a git commit bump
          return if git_source? && !ref_changed?

          # If there is a changelog, and it includes the new version, return it
          if new_version && default_branch_changelog &&
             fetch_file_text(default_branch_changelog)&.include?(new_version)
            return default_branch_changelog
          end

          # Otherwise, look for a changelog at the tag for this version
          if new_version && relevant_tag_changelog &&
             fetch_file_text(relevant_tag_changelog)&.include?(new_version)
            return relevant_tag_changelog
          end

          # Fall back to the changelog (or nil) from the default branch
          default_branch_changelog
        end
        # rubocop:enable Metrics/CyclomaticComplexity
        # rubocop:enable Metrics/PerceivedComplexity

        def default_branch_changelog
          return unless source

          @default_branch_changelog ||= changelog_from_ref(nil)
        end

        def relevant_tag_changelog
          return unless source
          return unless tag_for_new_version

          @relevant_tag_changelog ||= changelog_from_ref(tag_for_new_version)
        end

        def changelog_from_ref(ref)
          files =
            dependency_file_list(ref).
            select { |f| f.type == "file" }.
            reject { |f| f.name.end_with?(".sh") }.
            reject { |f| f.size > 1_000_000 }

          CHANGELOG_NAMES.each do |name|
            candidates = files.select { |f| f.name =~ /#{name}/i }
            file = candidates.first if candidates.one?
            file ||=
              candidates.find do |f|
                candidates -= [f] && next if fetch_file_text(f).nil?
                ChangelogPruner.new(
                  dependency: dependency,
                  changelog_text: fetch_file_text(f)
                ).includes_new_version?
              end
            file ||= candidates.max_by(&:size)
            return file if file
          end

          nil
        end

        def tag_for_new_version
          CommitsFinder.new(
            dependency: dependency,
            source: source,
            credentials: credentials
          ).new_tag
        end

        def full_changelog_text
          return unless changelog

          fetch_file_text(changelog)
        end

        def fetch_file_text(file)
          @file_text ||= {}

          unless @file_text.key?(file.download_url)
            @file_text[file.download_url] =
              case source.provider
              when "github" then fetch_github_file(file)
              when "gitlab" then fetch_gitlab_file(file)
              when "bitbucket" then fetch_bitbucket_file(file)
              else raise "Unsupported provider '#{source.provider}"
              end
          end

          return unless @file_text[file.download_url].valid_encoding?

          @file_text[file.download_url].
            force_encoding("UTF-8").
            encode.sub(/\n*\z/, "")
        end

        def fetch_github_file(file)
          # Hitting the download URL directly causes encoding problems
          raw_content = github_client.get(file.url).content
          Base64.decode64(raw_content).force_encoding("UTF-8").encode
        end

        def fetch_gitlab_file(file)
          Excon.get(
            file.download_url,
            idempotent: true,
            **SharedHelpers.excon_defaults
          ).body
        end

        def fetch_bitbucket_file(file)
          bitbucket_client.get(file.download_url).body
        end

        def upgrade_guide
          return unless source

          # Upgrade guide usually won't be relevant for bumping anything other
          # than the major version
          return unless major_version_upgrade?

          dependency_file_list.
            select { |f| f.type == "file" }.
            select { |f| f.name.casecmp("upgrade.md").zero? }.
            reject { |f| f.size > 1_000_000 }.
            max_by(&:size)
        end

        def dependency_file_list(ref = nil)
          @dependency_file_list ||= {}
          @dependency_file_list[ref] ||= fetch_dependency_file_list(ref)
        end

        def fetch_dependency_file_list(ref)
          case source.provider
          when "github" then fetch_github_file_list(ref)
          when "bitbucket" then fetch_bitbucket_file_list
          when "gitlab" then fetch_gitlab_file_list
          when "azure" then [] # TODO: Fetch files from Azure
          else raise "Unexpected repo provider '#{source.provider}'"
          end
        end

        def fetch_github_file_list(ref)
          files = []

          if source.directory
            opts = { path: source.directory, ref: ref }.compact
            files += github_client.contents(source.repo, opts)
          end

          opts = { ref: ref }.compact
          files += github_client.contents(source.repo, opts)

          %w(doc docs).each do |dir_name|
            if files.any? { |f| f.name == dir_name && f.type == "dir" }
              opts = { path: dir_name, ref: ref }.compact
              files += github_client.contents(source.repo, opts)
            end
          end

          files
        rescue Octokit::NotFound
          []
        end

        def fetch_bitbucket_file_list
          branch = default_bitbucket_branch
          bitbucket_client.fetch_repo_contents(source.repo).map do |file|
            OpenStruct.new(
              name: file.fetch("path").split("/").last,
              type: file.fetch("type") == "commit_file" ? "file" : file["type"],
              size: file.fetch("size", 0),
              html_url: "#{source.url}/src/#{branch}/#{file['path']}",
              download_url: "#{source.url}/raw/#{branch}/#{file['path']}"
            )
          end
        rescue Dependabot::Clients::Bitbucket::NotFound
          []
        end

        def fetch_gitlab_file_list
          gitlab_client.repo_tree(source.repo).map do |file|
            OpenStruct.new(
              name: file.name,
              type: file.type == "blob" ? "file" : file.type,
              size: 0, # GitLab doesn't return file size
              html_url: "#{source.url}/blob/master/#{file.path}",
              download_url: "#{source.url}/raw/master/#{file.path}"
            )
          end
        rescue Gitlab::Error::NotFound
          []
        end

        def new_version
          @new_version ||= git_source? ? new_ref : dependency.version
          @new_version&.gsub(/^v/, "")
        end

        def previous_ref
          dependency.previous_requirements.map do |r|
            r.dig(:source, "ref") || r.dig(:source, :ref)
          end.compact.first
        end

        def new_ref
          dependency.requirements.map do |r|
            r.dig(:source, "ref") || r.dig(:source, :ref)
          end.compact.first
        end

        def ref_changed?
          previous_ref && new_ref && previous_ref != new_ref
        end

        # TODO: Refactor me so that Composer doesn't need to be special cased
        def git_source?
          # Special case Composer, which uses git as a source but handles tags
          # internally
          return false if dependency.package_manager == "composer"

          requirements = dependency.requirements
          sources = requirements.map { |r| r.fetch(:source) }.uniq.compact
          return false if sources.empty?
          raise "Multiple sources! #{sources.join(', ')}" if sources.count > 1

          source_type = sources.first[:type] || sources.first.fetch("type")
          source_type == "git"
        end

        def major_version_upgrade?
          return false unless dependency.version&.match?(/^\d/)
          return false unless dependency.previous_version&.match?(/^\d/)

          dependency.version.split(".").first.to_i -
            dependency.previous_version.split(".").first.to_i >= 1
        end

        def gitlab_client
          @gitlab_client ||= Dependabot::Clients::Gitlab.
                             for_gitlab_dot_com(credentials: credentials)
        end

        def github_client
          @github_client ||= Dependabot::Clients::GithubWithRetries.
                             for_github_dot_com(credentials: credentials)
        end

        def bitbucket_client
          @bitbucket_client ||= Dependabot::Clients::Bitbucket.
                                for_bitbucket_dot_org(credentials: credentials)
        end

        def default_bitbucket_branch
          @default_bitbucket_branch ||=
            bitbucket_client.fetch_default_branch(source.repo)
        end
      end
    end
  end
end
