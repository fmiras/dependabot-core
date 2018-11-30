# frozen_string_literal: true

require "json"
require "tmpdir"
require "excon"
require "English"
require "digest"

module Dependabot
  module SharedHelpers
    BUMP_TMP_FILE_PREFIX = "dependabot_"
    BUMP_TMP_DIR_PATH = "tmp"
    GIT_CONFIG_GLOBAL_PATH = File.expand_path("~/.gitconfig")

    class ChildProcessFailed < StandardError
      attr_reader :error_class, :error_message, :error_backtrace

      def initialize(error_class:, error_message:, error_backtrace:)
        @error_class = error_class
        @error_message = error_message
        @error_backtrace = error_backtrace

        msg = "Child process raised #{error_class} with message: "\
              "#{error_message}"
        super(msg)
        set_backtrace(error_backtrace)
      end
    end

    def self.in_a_temporary_directory(directory = "/")
      Dir.mkdir(BUMP_TMP_DIR_PATH) unless Dir.exist?(BUMP_TMP_DIR_PATH)
      Dir.mktmpdir(BUMP_TMP_FILE_PREFIX, BUMP_TMP_DIR_PATH) do |dir|
        path = Pathname.new(File.join(dir, directory)).expand_path
        FileUtils.mkpath(path)
        Dir.chdir(path) { yield(path) }
      end
    end

    def self.in_a_forked_process
      read, write = IO.pipe

      pid = fork do
        read.close
        result = yield
      rescue Exception => error # rubocop:disable Lint/RescueException
        result = { _error_details: { error_class: error.class.to_s,
                                     error_message: error.message,
                                     error_backtrace: error.backtrace } }
      ensure
        Marshal.dump(result, write)
        exit!(0)
      end

      write.close
      result = read.read
      Process.wait(pid)
      result = Marshal.load(result) # rubocop:disable Security/MarshalLoad

      return result unless result.is_a?(Hash) && result[:_error_details]

      raise ChildProcessFailed, result[:_error_details]
    end

    class HelperSubprocessFailed < StandardError
      def initialize(message, command)
        super(message)
        @command = command
      end

      def raven_context
        { fingerprint: [@command] }
      end
    end

    def self.run_helper_subprocess(command:, function:, args:, env: nil,
                                   popen_opts: {})
      raw_response = nil
      popen_args = [env, command, "w+"].compact
      IO.popen(*popen_args, popen_opts) do |process|
        process.write(JSON.dump(function: function, args: args))
        process.close_write
        raw_response = process.read
      end

      response = JSON.parse(raw_response)
      return response["result"] if $CHILD_STATUS.success?

      raise HelperSubprocessFailed.new(response["error"], command)
    rescue JSON::ParserError
      raise HelperSubprocessFailed.new(raw_response, command) if raw_response

      raise HelperSubprocessFailed.new("No output from command", command)
    end

    def self.excon_middleware
      Excon.defaults[:middlewares] + [Excon::Middleware::RedirectFollower]
    end

    def self.excon_defaults
      {
        connect_timeout: 5,
        write_timeout: 5,
        read_timeout: 5,
        omit_default_port: true,
        middlewares: excon_middleware
      }
    end

    def self.with_git_configured(credentials:)
      backup_git_config_path = stash_global_git_config
      configure_git_to_use_https_with_credentials(credentials)
      yield
    ensure
      reset_global_git_config(backup_git_config_path)
    end

    def self.configure_git_to_use_https_with_credentials(credentials)
      configure_git_to_use_https
      configure_git_credentials(credentials)
    end

    def self.configure_git_to_use_https
      # Note: we use --global here (rather than --system) so that Dependabot
      # can be run without privileged access
      run_shell_command(
        'git config --global --replace-all url."https://github.com/".'\
        "insteadOf ssh://git@github.com/ && "\
        'git config --global --add url."https://github.com/".'\
        "insteadOf ssh://git@github.com: && "\
        'git config --global --add url."https://github.com/".'\
        "insteadOf git@github.com: && "\
        'git config --global --add url."https://github.com/".'\
        "insteadOf git@github.com/ && "\
        'git config --global --add url."https://github.com/".'\
        "insteadOf git://github.com/"
      )
    end

    def self.configure_git_credentials(credentials)
      # Then add a file-based credential store that loads a file in this repo.
      # Under the hood this uses git credential-store, but it's invoked through
      # an wrapper binary that only allows non-mutative commands. Without this,
      # whenever the credentials are deemed to be invalid, they're erased.
      credential_helper_path =
        File.join(__dir__, "../../helpers/utils/git-credential-store-immutable")
      run_shell_command(
        "git config --global credential.helper "\
        "'#{credential_helper_path} --file=#{Dir.pwd}/git.store'"
      )

      # Build the content for our credentials file
      git_store_content = ""
      credentials.each do |cred|
        next unless cred["type"] == "git_source"

        authenticated_url =
          "https://#{cred.fetch('username')}:#{cred.fetch('password')}"\
          "@#{cred.fetch('host')}"

        git_store_content += authenticated_url + "\n"
      end

      # Save the file
      File.write("git.store", git_store_content)
    end

    def self.stash_global_git_config
      return unless File.exist?(GIT_CONFIG_GLOBAL_PATH)

      contents = File.read(GIT_CONFIG_GLOBAL_PATH)
      digest = Digest::SHA2.hexdigest(contents)[0...10]
      backup_path = GIT_CONFIG_GLOBAL_PATH + ".backup-#{digest}"

      FileUtils.mv(GIT_CONFIG_GLOBAL_PATH, backup_path)
      backup_path
    end

    def self.reset_global_git_config(backup_path)
      return if backup_path.nil?
      return unless File.exist?(backup_path)

      FileUtils.mv(backup_path, GIT_CONFIG_GLOBAL_PATH)
    end

    def self.run_shell_command(command)
      raw_response = nil
      IO.popen(command, err: %i(child out)) do |process|
        raw_response = process.read
      end

      # Raise an error with the output from the shell session if the
      # command returns a non-zero status
      return if $CHILD_STATUS.success?

      raise SharedHelpers::HelperSubprocessFailed.new(
        raw_response,
        command
      )
    end
  end
end
