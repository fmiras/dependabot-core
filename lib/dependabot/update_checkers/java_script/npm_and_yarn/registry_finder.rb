# frozen_string_literal: true

require "excon"
require "dependabot/update_checkers/java_script/npm_and_yarn"
require "dependabot/shared_helpers"

module Dependabot
  module UpdateCheckers
    module JavaScript
      class NpmAndYarn
        class RegistryFinder
          AUTH_TOKEN_REGEX = %r{//(?<registry>.*)/:_authToken=(?<token>.*)$}

          def initialize(dependency:, credentials:, npmrc_file: nil)
            @dependency = dependency
            @credentials = credentials
            @npmrc_file = npmrc_file
          end

          def registry
            locked_registry || first_registry_with_dependency_details
          end

          def auth_token
            known_registries.
              find { |cred| cred["registry"] == registry }&.
              fetch("token")
          end

          def dependency_url
            "#{registry_url}/#{escaped_dependency_name}"
          end

          private

          attr_reader :dependency, :credentials, :npmrc_file

          def first_registry_with_dependency_details
            @first_registry_with_dependency_details ||=
              known_registries.find do |details|
                token = details["token"]
                headers = token ? { "Authorization" => "Bearer #{token}" } : {}

                Excon.get(
                  "https://#{details['registry'].gsub(%r{/+$}, '')}/"\
                  "#{escaped_dependency_name}",
                  headers: headers,
                  idempotent: true,
                  middlewares: SharedHelpers.excon_middleware
                ).status < 400
              end&.fetch("registry")

            @first_registry_with_dependency_details ||= "registry.npmjs.org"
          end

          def registry_url
            return dependency_source.fetch(:url) if locked_registry
            "https://#{registry}"
          end

          def locked_registry
            source = dependency_source
            return unless source
            return unless source.fetch(:type) == "private_registry"

            source.fetch(:url).gsub("https://", "").gsub("http://", "")
          end

          def known_registries
            @known_registries ||=
              begin
                registries = []
                registries += credentials.select { |cred| cred["registry"] }

                npmrc_file&.content.to_s.scan(AUTH_TOKEN_REGEX) do
                  registries << {
                    "registry" => Regexp.last_match[:registry],
                    "token" => Regexp.last_match[:token]
                  }
                end

                registries.uniq
              end
          end

          # npm registries expect slashes to be escaped
          def escaped_dependency_name
            dependency.name.gsub("/", "%2F")
          end

          def dependency_source
            sources = dependency.requirements.
                      map { |r| r.fetch(:source) }.uniq.compact
            return sources.first unless sources.count > 1
            raise "Multiple sources! #{sources.join(', ')}"
          end
        end
      end
    end
  end
end