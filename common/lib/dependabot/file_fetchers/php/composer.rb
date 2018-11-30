# frozen_string_literal: true

require "dependabot/file_fetchers/base"

module Dependabot
  module FileFetchers
    module Php
      class Composer < Dependabot::FileFetchers::Base
        def self.required_files_in?(filenames)
          filenames.include?("composer.json")
        end

        def self.required_files_message
          "Repo must contain a composer.json."
        end

        private

        def fetch_files
          fetched_files = []
          fetched_files << composer_json
          fetched_files << composer_lock if composer_lock
          fetched_files << auth_json if auth_json
          fetched_files += path_dependencies
          fetched_files
        end

        def composer_json
          @composer_json ||= fetch_file_from_host("composer.json")
        end

        def composer_lock
          return @composer_lock if @composer_lock_lookup_attempted

          @composer_lock_lookup_attempted = true
          @composer_lock ||= fetch_file_if_present("composer.lock")
        end

        # Note: This is fetched but currently unused
        def auth_json
          @auth_json ||= fetch_file_if_present("auth.json")&.
                         tap { |f| f.support_file = true }
        end

        def path_dependencies
          @path_dependencies ||=
            begin
              composer_json_files = []
              unfetchable_deps = []

              path_sources.each do |path|
                directories = path.end_with?("*") ? expand_path(path) : [path]

                directories.each do |dir|
                  file = File.join(dir, "composer.json")

                  begin
                    composer_json_files << fetch_file_with_root_fallback(file)
                  rescue Dependabot::DependencyFileNotFound
                    # Collected, but currently ignored
                    unfetchable_deps << file
                  end
                end
              end

              # Mark the path dependencies as support files - we don't currently
              # parse or update them.
              composer_json_files.tap do |files|
                files.each { |f| f.support_file = true }
              end
            end
        end

        def path_sources
          @path_sources ||=
            JSON.parse(composer_json.content).
            fetch("repositories", []).
            select { |details| details["type"] == "path" }.
            map { |details| details["url"] }
        rescue JSON::ParserError
          raise Dependabot::DependencyFileNotParseable, composer_json.path
        end

        def expand_path(path)
          repo_contents(dir: path.gsub(/\*$/, "")).
            select { |file| file.type == "dir" }.
            map { |f| path.gsub(/\*$/, f.name) }
        rescue Octokit::NotFound, Gitlab::Error::NotFound
          # If there's no lockfile, or if none of the dependencies are path
          # dependencies, then we can ignore failures to find path deps
          return [] unless composer_lock&.content&.include?('"path"')

          # Otherwise, we don't know what to do. For now, just raise. If we see
          # this in the wild we can make a call on the correct handling
          raise if directory == "/"

          # If the directory isn't found at the full path, try looking for it
          # at the root of the repository.
          depth = directory.gsub(%r{^/}, "").gsub(%r{/$}, "").split("/").count
          dir = "../" * depth + path.gsub(/\*$/, "")

          repo_contents(dir: dir).
            select { |file| file.type == "dir" }.
            map { |f| path.gsub(/\*$/, f.name) }
        end

        def fetch_file_with_root_fallback(filename, type: "file")
          path = Pathname.new(File.join(directory, filename)).cleanpath.to_path

          begin
            fetch_file_from_host(filename, type: type)
          rescue Dependabot::DependencyFileNotFound
            # If the file isn't found at the full path, try looking for it
            # without considering the directory (i.e., check if the path should
            # have been relevative to the root of the repository).
            cleaned_filename = Pathname.new(filename).cleanpath.to_path

            DependencyFile.new(
              name: cleaned_filename,
              content: fetch_file_content(cleaned_filename),
              directory: directory,
              type: type
            )
          end
        rescue Octokit::NotFound, Gitlab::Error::NotFound
          raise Dependabot::DependencyFileNotFound, path
        end
      end
    end
  end
end
