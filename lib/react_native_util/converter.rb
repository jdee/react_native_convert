require 'erb'
require 'json'
require 'tty/platform'
require 'xcodeproj'
require_relative 'util'

module ReactNativeUtil
  # Class to perform conversion operations.
  class Converter
    include Util

    # [Array<String>] Default contents of Libraries group
    DEFAULT_DEPENDENCIES = %w[
      RCTAnimation
      React
      RCTActionSheet
      RCTBlob
      RCTGeolocation
      RCTImage
      RCTLinking
      RCTNetwork
      RCTSettings
      RCTText
      RCTVibration
      RCTWebSocket
    ]

    # [String] Path to the Podfile template
    PODFILE_TEMPLATE_PATH = File.expand_path '../assets/templates/Podfile.erb', __dir__

    # [Hash] Contents of ./package.json
    attr_reader :package_json

    # [String] Full path to Xcode project
    attr_reader :xcodeproj_path

    # [Xcodeproj::Project] Contents of the project at xcodproj_path
    attr_reader :xcodeproj

    attr_reader :options

    def initialize(repo_update: nil)
      @options = {}
      if repo_update.nil?
        @options[:repo_update] = boolean_env_var?(:REACT_NATIVE_UTIL_REPO_UPDATE, default_value: true)
      else
        @options[:repo_update] = repo_update
      end
    end

    # Convert project to use React pod
    # @raise ConversionError on failure
    def convert_to_react_pod!
      raise ConversionError, "macOS required." unless mac?

      # Make sure no uncommitted changes
      check_repo_status!

      load_package_json!
      log 'package.json:'
      log " app name: #{app_name.inspect}"

      log 'Installing NPM dependencies with yarn'
      execute 'yarn'

      # 1. Detect project. TODO: Add an option to override.
      @xcodeproj_path = File.expand_path "ios/#{package_json['name']}.xcodeproj"
      load_xcodeproj!
      log "Found Xcode project at #{xcodeproj_path}"

      if libraries_group.nil?
        log "Libraries group not found in #{xcodeproj_path}. No conversion necessary."
        exit 0
      end

      # 2. Detect native dependencies in Libraries group.
      log 'Dependencies:'
      dependencies.each { |d| log " #{d}" }

      # Save for after Libraries removed.
      deps_to_add = dependencies

      # 3. Run react-native unlink for each one.
      dependencies.each do |dep|
        execute 'react-native', 'unlink', dep
      end

      # reload after react-native unlink
      load_xcodeproj!

      # 4a. TODO: Add Start Packager script
      validate_app_target!
      add_packager_script

      # 4b. Remove Libraries group from Xcode project.
      remove_libraries_group_from_project!

      xcodeproj.save

      # 5. Generate boilerplate Podfile.
      # TODO: Determine appropriate subspecs from contents of Libraries group
      generate_podfile!

      # 6. Run react-native link for each dependency.
      deps_to_add.each do |dep|
        execute 'react-native', 'link', dep
      end

      # 7. pod install
      command = %w[pod install --silent]
      command << '--repo-update' if options[:repo_update]
      execute(*command, chdir: 'ios')

      # 8. SCM/git (add, commit - optional)

      # 9. Open workspace/build
      execute 'open', File.join('ios', "#{app_name}.xcworkspace")
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

    # Load the project at @xcodeproj_path into @xcodeproj
    # @raise ConversionError on failure
    def load_xcodeproj!
      @xcodeproj = nil # in case of exception on reopen
      @xcodeproj = Xcodeproj::Project.open xcodeproj_path
    rescue Errno::ENOENT
      raise ConversionError, "Failed to open #{xcodeproj_path}. File not found."
    rescue Xcodeproj::PlainInformative => e
      raise ConversionError, "Failed to load #{xcodeproj_path}: #{e.message}"
    end

    # A representation of the Libraries group (if any) from the Xcode project.
    # @return the Libraries group
    def libraries_group
      xcodeproj['Libraries']
    end

    # Remove the Libraries group from the xcodeproj in memory.
    # Resets @libraries_group to nil as well.
    def remove_libraries_group_from_project!
      # Remove links against these static libraries
      xcodeproj.targets.reject { |t| t.name =~ /-tvOS/ }.each do |t|
        remove_libraries_from_target t
      end

      log 'Removing Libraries group'
      libraries_group.remove_from_project
    end

    def remove_libraries_from_target(target)
      log "Removing Libraries from #{target.name}"
      to_remove = target.frameworks_build_phase.files.select do |file|
        path = file.file_ref.pretty_print
        next false unless /^lib(.+)\.a$/.match?(path)

        static_libs.include?(path)
      end

      to_remove.each { |f| target.frameworks_build_phase.remove_build_file f }
    end

    # A list of external dependencies from NPM requiring react-native link.
    # @return [Array<String>] a list of NPM package names
    def dependencies
      return [] if libraries_group.nil?

      dependency_paths.map do |path|
        # Find the root above the ios/*.xcodeproj under node_modules
        root = File.expand_path '../..', path
        File.basename root
      end
    end

    # Paths to Xcode projects in the Libraries group from external deps.
    # @return [Array<String>] a list of absolute paths to Xcode projects
    def dependency_paths
      return [] if libraries_group.nil?

      paths = libraries_group.children.reject { |c| DEFAULT_DEPENDENCIES.include?(c.name.sub(/\.xcodeproj$/, '')) }.map(&:path)
      paths.map { |p| File.expand_path p, File.join(Dir.pwd, 'ios') }
    end

    # All static libraries from the Libraries group
    # @return [Array<String>] an array of filenames
    def static_libs
      libraries_group.children.map do |library|
        root = File.basename(library.path).sub(/\.xcodeproj$/, '')
        "lib#{root}.a"
      end
    end

    # The name of the app as specified in package.json
    # @return [String] the app name
    def app_name
      @app_name ||= package_json['name']
    end

    def test_target
      xcodeproj.targets.select(&:test_target_type?).reject { |t| t.name =~ /tvOS/ }.first
    end

    # Validate an assumption about the project. TODO: Provide override option.
    # @raise ConversionError if an application target is not found with the same name as the project.
    def validate_app_target!
      app_target = xcodeproj.targets.find { |t| t.name = app_name }
      raise ConversionError, "Unable to find target #{app_name} in #{xcodeproj_path}." if app_target.nil?
      raise ConversionError, "Target #{app_name} is not an application target." unless app_target.product_type == 'com.apple.product-type.application'
    end

    # Generate a Podfile from a template.
    def generate_podfile!
      podfile_contents = ERB.new(File.read(PODFILE_TEMPLATE_PATH)).result binding
      File.open 'ios/Podfile', 'w' do |file|
        file.write podfile_contents
      end
    end

    def check_repo_status!
      # If the git command is not installed, there's not much we can do.
      # Don't want to use verify_git here, which will insist on installing
      # the command. The logic of that method could change.
      return if `which git`.empty?

      unless Dir.exist? ".git"
        `git rev-parse --git-dir > /dev/null 2>&1`
        # Not a git repo
        return unless $?.success?
      end

      `git diff-index --quiet HEAD --`
      return if $?.success?

      raise ConversionError, 'Uncommitted changes in repo. Please commit or stash before continuing.'
    end

    def add_packager_script
      script = packager_script
      return unless script

      target = xcodeproj.targets.find { |t| t.name == app_name }
      phase = target.new_shell_script_build_phase 'Start Packager'
      phase.shell_script = script

      # TODO: Move this build phase to the top of the list before the pod install.
    end

    def react_project!
      return @react_project if @react_project

      path = libraries_group.children.find { |c| c.path =~ /React.xcodeproj/ }.real_path
      @react_project = Xcodeproj::Project.open path
    end

    def packager_script
      react_project!.targets.first.build_phases.find { |p| p.name =~ /packager/i }.shell_script.gsub(%r{../scripts}, '../node_modules/react-native/scripts')
    rescue Errno::ENOENT
      log 'Could not open React.xcodeproj. File not found.'
      nil
    rescue Xcodeproj::PlainInformative => e
      log "Could not open React.xcodeproj. #{e.message}"
      nil
    end
  end
end
