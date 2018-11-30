# frozen_string_literal: true

require "excon"
require "nokogiri"

require "dependabot/utils/dotnet/version"
require "dependabot/utils/dotnet/requirement"
require "dependabot/update_checkers/dotnet/nuget"
require "dependabot/shared_helpers"

module Dependabot
  module UpdateCheckers
    module Dotnet
      class Nuget
        class VersionFinder
          require_relative "repository_finder"

          def initialize(dependency:, dependency_files:, credentials:,
                         ignored_versions: [])
            @dependency = dependency
            @dependency_files = dependency_files
            @credentials = credentials
            @ignored_versions = ignored_versions
          end

          def latest_version_details
            @latest_version_details ||=
              begin
                tmp_versions = versions
                unless wants_prerelease?
                  tmp_versions.reject! { |d| d.fetch(:version).prerelease? }
                end
                tmp_versions.reject! do |hash|
                  ignore_reqs.any? { |r| r.satisfied_by?(hash.fetch(:version)) }
                end
                tmp_versions.max_by { |hash| hash.fetch(:version) }
              end
          end

          def versions
            available_v3_versions + available_v2_versions
          end

          attr_reader :dependency, :dependency_files, :credentials,
                      :ignored_versions

          private

          def available_v3_versions
            v3_nuget_listings.flat_map do |listing|
              listing.
                fetch("versions", []).
                map do |v|
                  nuspec_url =
                    listing.fetch("listing_details").
                    fetch(:versions_url).
                    gsub(/index\.json$/, "#{v}/#{sanitized_name}.nuspec")

                  {
                    version: version_class.new(v),
                    nuspec_url: nuspec_url,
                    source_url: nil,
                    repo_url:
                      listing.fetch("listing_details").fetch(:repository_url)
                  }
                end
            end
          end

          def available_v2_versions
            v2_nuget_listings.flat_map do |listing|
              body = listing.fetch("xml_body", [])
              doc = Nokogiri::XML(body)
              doc.remove_namespaces!

              doc.xpath("/feed/entry").map do |entry|
                listed = entry.at_xpath("./properties/Listed")&.content&.strip
                next if listed&.casecmp("false")&.zero?

                entry_details = dependency_details_from_v2_entry(entry)
                entry_details.merge(
                  repo_url: listing.fetch("listing_details").
                            fetch(:repository_url)
                )
              end.compact
            end
          end

          def dependency_details_from_v2_entry(entry)
            version = entry.at_xpath("./properties/Version").content.strip
            source_urls = []
            [
              entry.at_xpath("./properties/ProjectUrl").content,
              entry.at_xpath("./properties/ReleaseNotes").content
            ].join(" ").scan(Source::SOURCE_REGEX) do
              source_urls << Regexp.last_match.to_s
            end

            source_url = source_urls.find { |url| Source.from_url(url) }
            source_url = Source.from_url(source_url)&.url if source_url

            {
              version: version_class.new(version),
              nuspec_url: nil,
              source_url: source_url
            }
          end

          def wants_prerelease?
            if dependency.version &&
               version_class.correct?(dependency.version) &&
               version_class.new(dependency.version).prerelease?
              return true
            end

            dependency.requirements.any? do |req|
              reqs = (req.fetch(:requirement) || "").split(",").map(&:strip)
              reqs.any? { |r| r.include?("-") }
            end
          end

          def v3_nuget_listings
            return @v3_nuget_listings unless @v3_nuget_listings.nil?

            dependency_urls.
              select { |details| details.fetch(:repository_type) == "v3" }.
              map do |url_details|
                versions = versions_for_v3_repository(url_details)
                next unless versions

                { "versions" => versions, "listing_details" => url_details }
              end.compact
          end

          def v2_nuget_listings
            return @v2_nuget_listings unless @v2_nuget_listings.nil?

            dependency_urls.
              select { |details| details.fetch(:repository_type) == "v2" }.
              map do |url_details|
                response = Excon.get(
                  url_details[:versions_url],
                  headers: url_details[:auth_header],
                  idempotent: true,
                  **excon_defaults
                )
                next unless response.status == 200

                {
                  "xml_body" => response.body,
                  "listing_details" => url_details
                }
              end.compact
          end

          def versions_for_v3_repository(repository_details)
            # If we have a search URL we use it (since it will exclude unlisted
            # versions)
            if repository_details[:search_url]
              response = Excon.get(
                repository_details[:search_url],
                headers: repository_details[:auth_header],
                idempotent: true,
                **excon_defaults
              )
              return unless response.status == 200

              JSON.parse(response.body).fetch("data").
                find { |d| d.fetch("id").casecmp(sanitized_name).zero? }&.
                fetch("versions")&.
                map { |d| d.fetch("version") }
            # Otherwise, use the versions URL
            elsif repository_details[:versions_url]
              response = Excon.get(
                repository_details[:versions_url],
                headers: repository_details[:auth_header],
                idempotent: true,
                **excon_defaults
              )
              return unless response.status == 200

              JSON.parse(response.body).fetch("versions")
            end
          end

          def dependency_urls
            @dependency_urls ||=
              RepositoryFinder.new(
                dependency: dependency,
                credentials: credentials,
                config_file: nuget_config
              ).dependency_urls
          end

          def ignore_reqs
            ignored_versions.map { |req| requirement_class.new(req.split(",")) }
          end

          def nuget_config
            @nuget_config ||=
              dependency_files.find { |f| f.name.casecmp("nuget.config").zero? }
          end

          def sanitized_name
            dependency.name.downcase
          end

          def version_class
            Utils::Dotnet::Version
          end

          def requirement_class
            Utils::Dotnet::Requirement
          end

          def excon_defaults
            # For large JSON files we sometimes need a little longer than for
            # other languages. For example, see:
            # https://dotnet.myget.org/F/aspnetcore-dev/api/v3/query?
            # q=microsoft.aspnetcore.mvc&prerelease=true
            SharedHelpers.excon_defaults.merge(
              connect_timeout: 10,
              write_timeout: 10,
              read_timeout: 10
            )
          end
        end
      end
    end
  end
end
