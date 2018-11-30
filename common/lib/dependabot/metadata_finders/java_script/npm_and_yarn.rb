# frozen_string_literal: true

require "excon"
require "dependabot/metadata_finders/base"
require "dependabot/shared_helpers"
require "dependabot/utils"

module Dependabot
  module MetadataFinders
    module JavaScript
      class NpmAndYarn < Dependabot::MetadataFinders::Base
        def homepage_url
          # Attempt to use version_listing first, as fetching the entire listing
          # array can be slow (if it's large)
          if latest_version_listing["homepage"]
            return latest_version_listing["homepage"]
          end

          listing = all_version_listings.find { |_, l| l["homepage"] }
          listing&.last&.fetch("homepage", nil) || super
        end

        private

        def look_up_source
          return find_source_from_registry if new_source.nil?

          source_type = new_source[:type] || new_source.fetch("type")

          case source_type
          when "git" then find_source_from_git_url
          when "private_registry" then find_source_from_registry
          else raise "Unexpected source type: #{source_type}"
          end
        end

        def find_source_from_registry
          # Attempt to use version_listing first, as fetching the entire listing
          # array can be slow (if it's large)
          potential_source_urls =
            [
              get_url(latest_version_listing["repository"]),
              get_url(latest_version_listing["homepage"]),
              get_url(latest_version_listing["bugs"])
            ].compact

          source_url = potential_source_urls.find { |url| Source.from_url(url) }
          return Source.from_url(source_url) if Source.from_url(source_url)

          potential_source_urls =
            all_version_listings.flat_map do |_, listing|
              [
                get_url(listing["repository"]),
                get_url(listing["homepage"]),
                get_url(listing["bugs"])
              ]
            end.compact

          source_url = potential_source_urls.find { |url| Source.from_url(url) }
          Source.from_url(source_url)
        end

        def new_source
          sources = dependency.requirements.
                    map { |r| r.fetch(:source) }.uniq.compact

          raise "Multiple sources! #{sources.join(', ')}" if sources.count > 1

          sources.first
        end

        def get_url(details)
          case details
          when String then details
          when Hash then details.fetch("url", nil)
          end
        end

        def find_source_from_git_url
          url = new_source[:url] || new_source.fetch("url")
          Source.from_url(url)
        end

        def latest_version_listing
          return @latest_version_listing if @version_listing_lookup_attempted

          @version_listing_lookup_attempted = true

          response = Excon.get(
            "#{dependency_url}/latest",
            headers: registry_auth_headers,
            idempotent: true,
            **SharedHelpers.excon_defaults
          )

          if response.status == 200
            return @latest_version_listing = JSON.parse(response.body)
          end

          @latest_version_listing = {}
        rescue JSON::ParserError, Excon::Error::Timeout
          @latest_version_listing = {}
        end

        def all_version_listings
          return [] if npm_listing["versions"].nil?

          npm_listing["versions"].
            reject { |_, details| details["deprecated"] }.
            sort_by { |version, _| Utils::JavaScript::Version.new(version) }.
            reverse
        end

        def npm_listing
          return @npm_listing unless @npm_listing.nil?

          response = Excon.get(
            dependency_url,
            headers: registry_auth_headers,
            idempotent: true,
            **SharedHelpers.excon_defaults
          )

          return @npm_listing = {} if response.status >= 500

          begin
            @npm_listing = JSON.parse(response.body)
          rescue JSON::ParserError
            raise unless non_standard_registry?

            @npm_listing = {}
          end
        rescue Excon::Error::Timeout
          @npm_listing = {}
        end

        def dependency_url
          registry_url =
            if new_source.nil? then "https://registry.npmjs.org"
            else new_source.fetch(:url)
            end

          # NPM registries expect slashes to be escaped
          escaped_dependency_name = dependency.name.gsub("/", "%2F")
          "#{registry_url}/#{escaped_dependency_name}"
        end

        def registry_auth_headers
          return {} unless auth_token

          { "Authorization" => "Bearer #{auth_token}" }
        end

        def dependency_registry
          if new_source.nil? then "registry.npmjs.org"
          else new_source.fetch(:url).gsub("https://", "").gsub("http://", "")
          end
        end

        def auth_token
          credentials.
            select { |cred| cred["type"] == "npm_registry" }.
            find { |cred| cred["registry"] == dependency_registry }&.
            fetch("token")
        end

        def private_dependency_not_reachable?(npm_response)
          # Check whether this dependency is (likely to be) private
          if dependency_registry == "registry.npmjs.org" &&
             !dependency.name.start_with?("@")
            return false
          end

          [401, 403, 404].include?(npm_response.status)
        end

        def non_standard_registry?
          dependency_registry != "registry.npmjs.org"
        end
      end
    end
  end
end
