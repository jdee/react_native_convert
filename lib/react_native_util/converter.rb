require 'cocoapods-core'
require 'erb'
require 'json'
require 'rubygems'
require_relative 'metadata'
require_relative 'project'

module ReactNativeUtil
  # Class to perform conversion operations.
  class Converter
    include Util

    # [String] Path to the Podfile template
    PODFILE_TEMPLATE_PATH = File.expand_path '../assets/templates/Podfile.erb', __dir__

    REQUIRED_COMMANDS = [:yarn, 'react-native' => 'react-native-cli']

    # [Hash] Contents of ./package.json
    attr_reader :package_json

    # [String] Full path to Xcode project
    attr_reader :xcodeproj_path

    # [Project] Contents of the project at xcodeproj_path
    attr_reader :project

    attr_reader :options
    attr_reader :react_project
    attr_reader :react_podspec

    def initialize(repo_update: nil)
      @options = {}
      if repo_update.nil?
        @options[:repo_update] = boolean_env_var?(:REACT_NATIVE_UTIL_REPO_UPDATE, default_value: true)
      else
        @options[:repo_update] = repo_update
      end
    end

    # Convert project to use React pod. Expects the app's package.json in the
    # current directory.
    #
    #     require 'react_native_util/converter'
    #
    #     Dir.chdir '/path/to/rn/project' do
    #       begin
    #         ReactNativeUtil::Converter.new(repo_update: true).convert_to_react_pod!
    #       rescue ReactNativeUtil::BaseException => e
    #         # All exceptions generated by this gem inherit from
    #         # ReactNativeUtil::BaseException.
    #         puts "Error from #convert_to_react_pod!: #{e.message}"
    #       end
    #     end
    #
    # @raise ConversionError on conversion failure
    # @raise ExecutionError on generic command failure
    # @raise Errno::ENOENT if a required command is not present
    def convert_to_react_pod!
      startup!

      if project.libraries_group.nil?
        log "Libraries group not found in #{xcodeproj_path}. No conversion necessary."
        return
      end

      if File.exist? podfile_path
        log "Podfile already present at #{File.expand_path podfile_path}.".red.bold
        log "A future release of #{NAME} may support integration with an existing Podfile."
        log 'This release can only convert apps that do not currently use a Podfile.'
        exit 1
      end

      # Not used at the moment
      # load_react_podspec!

      # 1. Detect native dependencies in Libraries group.
      log 'Dependencies:'
      project.dependencies.each { |d| log " #{d}" }

      # Save for after Libraries removed.
      deps_to_add = project.dependencies

      # 2. Run react-native unlink for each one.
      log 'Unlinking dependencies'
      project.dependencies.each do |dep|
        run_command_with_spinner! 'react-native', 'unlink', dep, log: File.join(Dir.tmpdir, "react-native-unlink-#{dep}.log")
      end

      # reload after react-native unlink
      load_xcodeproj!
      load_react_project!

      # 3. Add Start Packager script
      project.add_packager_script_from react_project

      # 4. Generate boilerplate Podfile.
      generate_podfile!

      # 5. Remove Libraries group from Xcode project.
      project.remove_libraries_group
      project.save

      # 6. Run react-native link for each dependency (adds to Podfile).
      log 'Linking dependencies'
      deps_to_add.each do |dep|
        run_command_with_spinner! 'react-native', 'link', dep, log: File.join(Dir.tmpdir, "react-native-link-#{dep}.log")
      end

      # 7. pod install
      # TODO: Can this be customized? Is this the only thing I have to look for
      # in case CocoaPods needs an initial setup? We pull it in as a dependency.
      # It could be they've never set it up before. Assume if this directory
      # exists, pod install is possible (possibly with --repo-update).
      master_podspec_repo_path = File.join ENV['HOME'], '.cocoapods', 'repos', 'master'
      unless Dir.exist?(master_podspec_repo_path)
        # The worst thing that can happen is this is equivalent to pod repo update.
        # But then pod install --repo-update will take very little time.
        log 'Setting up CocoaPods'
        run_command_with_spinner! 'pod', 'setup', log: File.join(Dir.tmpdir, 'pod-setup.log')
      end

      log "Generating Pods project and ios/#{app_name}.xcworkspace"
      log 'Once pod install is complete, your project will be part of this workspace.'
      log 'From now on, you should build the workspace with Xcode instead of the project.'
      log 'Always add the workspace and Podfile.lock to SCM.'
      log 'It is common practice also to add the Pods directory.'
      log 'The workspace will be automatically opened when pod install completes.'
      command = %w[pod install]
      command << '--repo-update' if options[:repo_update]
      run_command_with_spinner!(*command, chdir: 'ios', log: File.join(Dir.tmpdir, 'pod-install.log'))

      log 'Conversion complete ✅'

      # 8. Open workspace/build
      execute 'open', File.join('ios', "#{app_name}.xcworkspace")

      # 9. TODO: SCM/git (add, commit - optional)
      # See https://github.com/jdee/react_native_util/issues/18
    end

    def update_project!
      startup!

      unless project.libraries_group.nil?
        raise ConversionError, "Libraries group present in #{xcodeproj_path}. Conversion necessary. Run rn react_pod without -u."
      end

      unless File.exist? podfile_path
        raise ConversionError, "#{podfile_path} not found. Conversion necessary. Run rn react_pod without -u."
      end

      log "Updating project at #{xcodeproj_path}"

      # Check/update the contents of the packager script in React.xcodeproj
      load_react_project!

      current_script_phase = project.packager_phase

      # Not an error. User may have removed it.
      log "Packager build phase not found in #{xcodeproj_path}. Not updating.".yellow and return if current_script_phase.nil?

      new_script_phase = react_project.packager_phase
      # Totally unexpected. Exception. TODO: This is not treated as an error on conversion. Probably should be.
      raise ConversionError, "Packager build phase not found in #{react_project.path}." if new_script_phase.nil?

      new_script = new_script_phase.shell_script.gsub %r{../scripts}, '../node_modules/react-native/scripts'

      if new_script == current_script_phase.shell_script && new_script_phase.name == current_script_phase.name
        log "#{current_script_phase.name} build phase up to date. ✅"
        return
      end

      log 'Updating packager phase.'
      log " Current name: #{current_script_phase.name}"
      log " New name    : #{new_script_phase.name}"

      current_script_phase.name = new_script_phase.name
      current_script_phase.shell_script = new_script

      project.save

      log "Updated #{xcodeproj_path} ✅"
    end

    def startup!
      validate_commands! REQUIRED_COMMANDS

      # Make sure no uncommitted changes
      check_repo_status!

      report_configuration!

      raise ConversionError, "macOS required." unless mac?

      load_package_json!
      log 'package.json:'
      log " app name: #{app_name.inspect}"

      # Detect project. TODO: Add an option to override.
      @xcodeproj_path = File.expand_path "ios/#{app_name}.xcodeproj"
      load_xcodeproj!
      log "Found Xcode project at #{xcodeproj_path}"

      project.validate_app_target!
    end

    # Read the contents of ./package.json into @package_json
    # @raise ConversionError on failure
    def load_package_json!
      @package_json = File.open('package.json') { |f| JSON.parse f.read }
    rescue Errno::ENOENT
      raise ConversionError, 'Failed to load package.json. File not found. Please run from the project root.'
    rescue JSON::ParserError => e
      raise ConversionError, "Failed to parse package.json: #{e.message}"
    end

    def install_npm_deps_if_needed!
      raise ConversionError, 'package.json not found. Please run from the project root.' unless File.readable?('package.json')

      execute 'yarn', 'check', '--integrity', log: nil, output: :close
      execute 'yarn', 'check', '--verify-tree', log: nil, output: :close
    rescue ExecutionError
      # install deps if either check fails
      run_command_with_spinner! 'yarn', 'install', log: File.join(Dir.tmpdir, 'yarn.log')
    end

    def report_configuration!
      log "#{NAME} react_pod v#{VERSION}".bold

      install_npm_deps_if_needed!

      log ' Installed from Homebrew' if ENV['REACT_NATIVE_UTIL_INSTALLED_FROM_HOMEBREW']

      log " #{`uname -msr`}"

      log " Ruby #{RUBY_VERSION}: #{RbConfig.ruby}"
      log " RubyGems #{Gem::VERSION}: #{`which gem`}"
      log " Bundler #{Bundler::VERSION}: #{`which bundle`}" if defined?(Bundler)

      log_command_path 'react-native', 'react-native-cli', include_version: false
      unless `which react-native`.empty?
        react_native_info = `react-native --version`
        react_native_info.split("\n").each { |l| log "  #{l}" }
      end

      log_command_path 'yarn'
      log_command_path 'pod', 'cocoapods'

      log " cocoapods-core: #{Pod::CORE_VERSION}"
    rescue Errno::ENOENT
      # On Windows, e.g., which and uname may not work.
      log 'Conversion failed: macOS required.'.red.bold
      exit(-1)
    end

    def log_command_path(command, package = command, include_version: true)
      path = `which #{command}`
      if path.empty?
        log " #{package}: #{'not found'.red.bold}"
        return
      end

      if include_version
        version = `#{command} --version`.chomp
        log " #{package} #{version}: #{path}"
      else
        log " #{package}: #{path}"
      end
    end

    # Load the project at @xcodeproj_path into @xcodeproj
    # @raise ConversionError on failure
    def load_xcodeproj!
      @project = nil # in case of exception on reopen
      @project = Project.open xcodeproj_path
      @project.app_name = app_name
    rescue Errno::ENOENT
      raise ConversionError, "Failed to open #{xcodeproj_path}. File not found."
    rescue Xcodeproj::PlainInformative => e
      raise ConversionError, "Failed to load #{xcodeproj_path}: #{e.message}"
    end

    def load_react_podspec!
      podspec_dir = 'node_modules/react-native'
      podspec_contents = File.read "#{podspec_dir}/React.podspec"
      podspec_contents.gsub!(/__dir__/, podspec_dir.inspect)

      require 'cocoapods-core'
      # rubocop: disable Security/Eval
      @react_podspec = eval(podspec_contents)
      # rubocop: enable Security/Eval
    end

    # The name of the app as specified in package.json
    # @return [String] the app name
    def app_name
      @app_name ||= package_json['name']
    end

    def app_target
      project.app_target
    end

    def test_target
      project.test_target
    end

    def podfile_path
      'ios/Podfile'
    end

    # Generate a Podfile from a template.
    def generate_podfile!
      log "Generating #{podfile_path}"
      podfile_contents = ERB.new(File.read(PODFILE_TEMPLATE_PATH)).result binding
      File.open podfile_path, 'w' do |file|
        file.write podfile_contents
      end
    end

    def check_repo_status!
      # If the git command is not installed, there's not much we can do.
      return if `which git`.empty?

      `git rev-parse --git-dir > /dev/null 2>&1`
      # Not a git repo
      return unless $?.success?

      `git diff-index --quiet HEAD --`
      return if $?.success?

      raise ConversionError, 'Uncommitted changes in repo. Please commit or stash before continuing.'
    end

    # Load the contents of the React.xcodeproj project from node_modules.
    # @raise Xcodeproj::PlainInformative in case of most failures
    def load_react_project!
      @react_project = Project.open 'node_modules/react-native/React/React.xcodeproj'
    end
  end
end
