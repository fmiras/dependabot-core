# frozen_string_literal: true

require "gitlab"
require "octokit"
require "dependabot/pull_request_creator"

# rubocop:disable Metrics/ClassLength
module Dependabot
  class PullRequestCreator
    class Labeler
      DEPENDENCIES_LABEL_REGEX = %r{^[^/]*dependenc[^/]+$}i.freeze
      LANGUAGE_LABEL_DETAILS = {
        "bundler" => { name: "ruby", colour: "ce2d2d" },
        "submodules" => { name: "submodules", colour: "000000" },
        "docker" => { name: "docker", colour: "21ceff" },
        "terraform" => { name: "terraform", colour: "5C4EE5" },
        "nuget" => { name: ".NET", colour: "7121c6" },
        "maven" => { name: "java", colour: "ffa221" },
        "gradle" => { name: "java", colour: "ffa221" },
        "npm_and_yarn" => { name: "javascript", colour: "168700" },
        "pip" => { name: "python", colour: "2b67c6" },
        "composer" => { name: "php", colour: "45229e" },
        "hex" => { name: "elixir", colour: "9380dd" },
        "cargo" => { name: "rust", colour: "000000" },
        "dep" => { name: "go", colour: "16e2e2" },
        "go_modules" => { name: "go", colour: "16e2e2" },
        "elm-package" => { name: "elm", colour: "76d3f2" }
      }.freeze

      def initialize(source:, custom_labels:, credentials:, dependencies:,
                     includes_security_fixes:, label_language:)
        @source                  = source
        @custom_labels           = custom_labels
        @credentials             = credentials
        @dependencies            = dependencies
        @includes_security_fixes = includes_security_fixes
        @label_language          = label_language
      end

      def create_default_labels_if_required
        create_default_dependencies_label_if_required
        create_default_security_label_if_required
        create_default_language_label_if_required
      end

      def labels_for_pr
        [
          *default_labels_for_pr,
          includes_security_fixes? ? security_label : nil,
          semver_labels_exist? ? semver_label : nil
        ].compact.uniq
      end

      def label_pull_request(pull_request_number)
        create_default_labels_if_required

        return if labels_for_pr.none?
        raise "Only GitHub!" unless source.provider == "github"

        github_client_for_source.add_labels_to_an_issue(
          source.repo,
          pull_request_number,
          labels_for_pr
        )
      end

      private

      attr_reader :source, :custom_labels, :credentials, :dependencies

      def label_language?
        @label_language
      end

      def includes_security_fixes?
        @includes_security_fixes
      end

      # rubocop:disable Metrics/CyclomaticComplexity
      # rubocop:disable Metrics/PerceivedComplexity
      def update_type
        return unless dependencies.any?(&:previous_version)

        precison = dependencies.map do |dep|
          new_version_parts = version(dep).split(".")
          old_version_parts = previous_version(dep)&.split(".") || []
          all_parts = new_version_parts.first(3) + old_version_parts.first(3)
          next 0 unless all_parts.all? { |part| part.to_i.to_s == part }
          next 1 if new_version_parts[0] != old_version_parts[0]
          next 2 if new_version_parts[1] != old_version_parts[1]

          3
        end.min

        case precison
        when 0 then "non-semver"
        when 1 then "major"
        when 2 then "minor"
        when 3 then "patch"
        end
      end
      # rubocop:enable Metrics/CyclomaticComplexity
      # rubocop:enable Metrics/PerceivedComplexity

      def version(dep)
        return dep.version if version_class.correct?(dep.version)

        source = dep.requirements.find { |r| r.fetch(:source) }&.fetch(:source)
        type = source&.fetch("type", nil) || source&.fetch(:type)
        return dep.version unless type == "git"

        ref = source.fetch("ref", nil) || source.fetch(:ref)
        version_from_ref = ref&.gsub(/^v/, "")
        return dep.version unless version_from_ref
        return dep.version unless version_class.correct?(version_from_ref)

        version_from_ref
      end

      def previous_version(dep)
        version_str = dep.previous_version
        return version_str if version_class.correct?(version_str)

        source = dep.previous_requirements.
                 find { |r| r.fetch(:source) }&.fetch(:source)
        type = source&.fetch("type", nil) || source&.fetch(:type)
        return version_str unless type == "git"

        ref = source.fetch("ref", nil) || source.fetch(:ref)
        version_from_ref = ref&.gsub(/^v/, "")
        return version_str unless version_from_ref
        return version_str unless version_class.correct?(version_from_ref)

        version_from_ref
      end

      def create_default_dependencies_label_if_required
        return if custom_labels
        return if dependencies_label_exists?

        create_dependencies_label
      end

      def create_default_security_label_if_required
        return unless includes_security_fixes?
        return if security_label_exists?

        create_security_label
      end

      def create_default_language_label_if_required
        return unless label_language?
        return if custom_labels
        return if language_label_exists?

        create_language_label
      end

      def default_labels_for_pr
        if custom_labels then custom_labels & labels
        else
          [
            labels.find { |l| l.match?(DEPENDENCIES_LABEL_REGEX) },
            label_language? ? language_label : nil
          ].compact
        end
      end

      def dependencies_label_exists?
        labels.any? { |l| l.match?(DEPENDENCIES_LABEL_REGEX) }
      end

      def security_label_exists?
        !security_label.nil?
      end

      def security_label
        labels.find { |l| l.match?(/security/i) }
      end

      def semver_labels_exist?
        (%w(major minor patch) - labels.map(&:downcase)).empty?
      end

      def semver_label
        return unless update_type

        labels.find { |l| l.downcase == update_type.to_s }
      end

      def language_label_exists?
        !language_label.nil?
      end

      def language_label
        label_name = LANGUAGE_LABEL_DETAILS.fetch(package_manager).fetch(:name)
        labels.find { |l| l.casecmp(label_name).zero? }
      end

      def labels
        @labels ||=
          case source.provider
          when "github" then fetch_github_labels
          when "gitlab" then fetch_gitlab_labels
          else raise "Unsupported provider #{source.provider}"
          end
      end

      def fetch_github_labels
        client = github_client_for_source

        labels =
          client.
          labels(source.repo, per_page: 100).
          map(&:name)

        next_link = client.last_response.rels[:next]

        while next_link
          next_page = next_link.get
          labels += next_page.data.map(&:name)
          next_link = next_page.rels[:next]
        end

        labels
      end

      def fetch_gitlab_labels
        gitlab_client_for_source.
          labels(source.repo).
          map(&:name)
      end

      def create_dependencies_label
        case source.provider
        when "github" then create_github_dependencies_label
        when "gitlab" then create_gitlab_dependencies_label
        else raise "Unsupported provider #{source.provider}"
        end
      end

      def create_security_label
        case source.provider
        when "github" then create_github_security_label
        when "gitlab" then create_gitlab_security_label
        else raise "Unsupported provider #{source.provider}"
        end
      end

      def create_language_label
        case source.provider
        when "github" then create_github_language_label
        when "gitlab" then create_gitlab_language_label
        else raise "Unsupported provider #{source.provider}"
        end
      end

      def create_github_dependencies_label
        github_client_for_source.add_label(
          source.repo, "dependencies", "0025ff",
          description: "Pull requests that update a dependency file",
          accept: "application/vnd.github.symmetra-preview+json"
        )
        @labels = [*@labels, "dependencies"].uniq
      rescue Octokit::UnprocessableEntity => error
        raise unless error.errors.first.fetch(:code) == "already_exists"

        @labels = [*@labels, "dependencies"].uniq
      end

      def create_gitlab_dependencies_label
        gitlab_client_for_source.create_label(
          source.repo, "dependencies", "#0025ff",
          description: "Pull requests that update a dependency file"
        )
        @labels = [*@labels, "dependencies"].uniq
      end

      def create_github_security_label
        github_client_for_source.add_label(
          source.repo, "security", "ee0701",
          description: "Pull requests that address a security vulnerability",
          accept: "application/vnd.github.symmetra-preview+json"
        )
        @labels = [*@labels, "security"].uniq
      rescue Octokit::UnprocessableEntity => error
        raise unless error.errors.first.fetch(:code) == "already_exists"

        @labels = [*@labels, "security"].uniq
      end

      def create_gitlab_security_label
        gitlab_client_for_source.create_label(
          source.repo, "security", "#ee0701",
          description: "Pull requests that address a security vulnerability"
        )
        @labels = [*@labels, "security"].uniq
      end

      def create_github_language_label
        langauge_name = LANGUAGE_LABEL_DETAILS.fetch(package_manager).
                        fetch(:name)
        github_client_for_source.add_label(
          source.repo,
          langauge_name,
          LANGUAGE_LABEL_DETAILS.fetch(package_manager).fetch(:colour),
          description: "Pull requests that update #{langauge_name.capitalize} "\
                       "code",
          accept: "application/vnd.github.symmetra-preview+json"
        )
        @labels = [*@labels, langauge_name].uniq
      rescue Octokit::UnprocessableEntity => error
        raise unless error.errors.first.fetch(:code) == "already_exists"

        @labels = [*@labels, langauge_name].uniq
      end

      def create_gitlab_language_label
        langauge_name = LANGUAGE_LABEL_DETAILS.fetch(package_manager).
                        fetch(:name)
        gitlab_client_for_source.create_label(
          source.repo,
          langauge_name,
          "#" + LANGUAGE_LABEL_DETAILS.fetch(package_manager).fetch(:colour)
        )
        @labels = [*@labels, langauge_name].uniq
      end

      def github_client_for_source
        @github_client_for_source ||=
          Dependabot::Clients::GithubWithRetries.for_source(
            source: source,
            credentials: credentials
          )
      end

      def gitlab_client_for_source
        access_token =
          credentials.
          select { |cred| cred["type"] == "git_source" }.
          find { |cred| cred["host"] == source.hostname }&.
          fetch("password")

        @gitlab_client_for_source ||=
          ::Gitlab.client(
            endpoint: source.api_endpoint,
            private_token: access_token || ""
          )
      end

      def package_manager
        @package_manager ||= dependencies.first.package_manager
      end

      def version_class
        Utils.version_class_for_package_manager(package_manager)
      end
    end
  end
end
# rubocop:enable Metrics/ClassLength
