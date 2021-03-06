require 'optparse'
require 'fileutils'
require 'rbconfig'

module Haml
  # This module handles the various Haml executables (`haml`, `sass`, `css2sass`, etc).
  module Exec
    # An abstract class that encapsulates the executable code for all three executables.
    class Generic
      # @param args [Array<String>] The command-line arguments
      def initialize(args)
        @args = args
        @options = {}
      end

      # Parses the command-line arguments and runs the executable.
      # Calls `Kernel#exit` at the end, so it never returns.
      def parse!
        begin
          @opts = OptionParser.new(&method(:set_opts))
          @opts.parse!(@args)

          process_result

          @options
        rescue Exception => e
          raise e if @options[:trace] || e.is_a?(SystemExit)

          $stderr.puts e.message
          exit 1
        end
        exit 0
      end

      # @return [String] A description of the executable
      def to_s
        @opts.to_s
      end

      protected

      # Finds the line of the source template
      # on which an exception was raised.
      #
      # @param exception [Exception] The exception
      # @return [String] The line number
      def get_line(exception)
        # SyntaxErrors have weird line reporting
        # when there's trailing whitespace,
        # which there is for Haml documents.
        return exception.message.scan(/:(\d+)/).first.first if exception.is_a?(::SyntaxError)
        exception.backtrace[0].scan(/:(\d+)/).first.first
      end

      # Tells optparse how to parse the arguments
      # available for all executables.
      #
      # This is meant to be overridden by subclasses
      # so they can add their own options.
      #
      # @param opts [OptionParser]
      def set_opts(opts)
        opts.on('-s', '--stdin', :NONE, 'Read input from standard input instead of an input file') do
          @options[:input] = $stdin
        end

        opts.on('--trace', :NONE, 'Show a full traceback on error') do
          @options[:trace] = true
        end

        if RbConfig::CONFIG['host_os'] =~ /mswin|windows/i
          opts.on('--unix-newlines', 'Use Unix-style newlines in written files.') do
            @options[:unix_newlines] = true
          end
        end

        opts.on_tail("-?", "-h", "--help", "Show this message") do
          puts opts
          exit
        end

        opts.on_tail("-v", "--version", "Print version") do
          puts("Haml/Sass #{::Haml.version[:string]}")
          exit
        end
      end

      # Processes the options set by the command-line arguments.
      # In particular, sets `@options[:input]` and `@options[:output]`
      # to appropriate IO streams.
      #
      # This is meant to be overridden by subclasses
      # so they can run their respective programs.
      def process_result
        input, output = @options[:input], @options[:output]
        input_file, output_file = if input
                                    [nil, open_file(@args[0], 'w')]
                                  else
                                    @options[:filename] = @args[0]
                                    [open_file(@args[0]), open_file(@args[1], 'w')]
                                  end

        input  ||= input_file
        output ||= output_file
        input  ||= $stdin
        output ||= $stdout

        @options[:input], @options[:output] = input, output
      end

      private

      def open_file(filename, flag = 'r')
        return if filename.nil?
        flag = 'wb' if @options[:unix_newlines] && flag == 'w'
        File.open(filename, flag)
      end
    end

    # An abstrac class that encapsulates the code
    # specific to the `haml` and `sass` executables.
    class HamlSass < Generic
      # @param args [Array<String>] The command-line arguments
      def initialize(args)
        super
        @options[:for_engine] = {}
      end

      protected

      # Tells optparse how to parse the arguments
      # available for the `haml` and `sass` executables.
      #
      # This is meant to be overridden by subclasses
      # so they can add their own options.
      #
      # @param opts [OptionParser]
      def set_opts(opts)
        opts.banner = <<END
Usage: #{@name.downcase} [options] [INPUT] [OUTPUT]

Description:
  Uses the #{@name} engine to parse the specified template
  and outputs the result to the specified file.

Options:
END

        opts.on('--rails RAILS_DIR', "Install Haml and Sass from the Gem to a Rails project") do |dir|
          original_dir = dir

          dir = File.join(dir, 'vendor', 'plugins')

          unless File.exists?(dir)
            puts "Directory #{dir} doesn't exist"
            exit
          end

          dir = File.join(dir, 'haml')

          if File.exists?(dir)
            print "Directory #{dir} already exists, overwrite [y/N]? "
            exit if gets !~ /y/i
            FileUtils.rm_rf(dir)
          end

          begin
            Dir.mkdir(dir)
          rescue SystemCallError
            puts "Cannot create #{dir}"
            exit
          end

          File.open(File.join(dir, 'init.rb'), 'w') do |file|
            file << File.read(File.dirname(__FILE__) + "/../../init.rb")
          end

          puts "Haml plugin added to #{original_dir}"
          exit
        end

        opts.on('-c', '--check', "Just check syntax, don't evaluate.") do
          require 'stringio'
          @options[:check_syntax] = true
          @options[:output] = StringIO.new
        end

        super
      end

      # Processes the options set by the command-line arguments.
      # In particular, sets `@options[:for_engine][:filename]` to the input filename
      # and requires the appropriate file.
      #
      # This is meant to be overridden by subclasses
      # so they can run their respective programs.
      def process_result
        super
        @options[:for_engine][:filename] = @options[:filename] if @options[:filename]
        require File.dirname(__FILE__) + "/../#{@name.downcase}"
      end
    end

    # The `sass` executable.
    class Sass < HamlSass
      # @param args [Array<String>] The command-line arguments
      def initialize(args)
        super
        @name = "Sass"
        @options[:for_engine][:load_paths] = ['.'] + (ENV['SASSPATH'] || '').split(File::PATH_SEPARATOR)
      end

      protected

      # Tells optparse how to parse the arguments.
      #
      # @param opts [OptionParser]
      def set_opts(opts)
        super

        opts.on('--watch', 'Watch files or directories for changes.',
                           'The location of the generated CSS can be set using a colon:',
                           '  sass --watch input.sass:output.css',
                           '  sass --watch input-dir:output-dir') do
          @options[:watch] = true
        end
        opts.on('--update', 'Compile files or directories to CSS.',
                            'Locations are set like --watch.') do
          @options[:update] = true
        end
        opts.on('-t', '--style NAME',
                'Output style. Can be nested (default), compact, compressed, or expanded.') do |name|
          @options[:for_engine][:style] = name.to_sym
        end
        opts.on('-l', '--line-numbers', '--line-comments',
                'Emit comments in the generated CSS indicating the corresponding sass line.') do
          @options[:for_engine][:line_numbers] = true
        end
        opts.on('-i', '--interactive',
                'Run an interactive SassScript shell.') do
          @options[:interactive] = true
        end
        opts.on('-I', '--load-path PATH', 'Add a sass import path.') do |path|
          @options[:for_engine][:load_paths] << path
        end
        opts.on('--cache-location PATH', 'The path to put cached Sass files. Defaults to .sass-cache.') do |loc|
          @options[:for_engine][:cache_location] = loc
        end
        opts.on('-C', '--no-cache', "Don't cache to sassc files.") do
          @options[:for_engine][:cache] = false
        end
      end

      # Processes the options set by the command-line arguments,
      # and runs the Sass compiler appropriately.
      def process_result
        if !@options[:update] && !@options[:watch] &&
            @args.first && @args.first.include?(':')
          if @args.size == 1
            @args = @args.first.split(':', 2)
          else
            @options[:update] = true
          end
        end

        return interactive if @options[:interactive]
        return watch_or_update if @options[:watch] || @options[:update]
        super

        begin
          input = @options[:input]
          output = @options[:output]

          tree =
            if input.is_a?(File) && !@options[:check_syntax]
              ::Sass::Files.tree_for(input.path, @options[:for_engine])
            else
              # We don't need to do any special handling of @options[:check_syntax] here,
              # because the Sass syntax checking happens alongside evaluation
              # and evaluation doesn't actually evaluate any code anyway.
              ::Sass::Engine.new(input.read(), @options[:for_engine]).to_tree
            end

          input.close() if input.is_a?(File)

          output.write(tree.render)
          output.close() if output.is_a? File
        rescue ::Sass::SyntaxError => e
          raise e if @options[:trace]
          raise e.sass_backtrace_str("standard input")
        end
      end

      private

      def interactive
        require 'sass'
        require 'sass/repl'
        ::Sass::Repl.new(@options).run
      end

      def watch_or_update
        require 'sass'
        require 'sass/plugin'
        ::Sass::Plugin.options[:unix_newlines] = @options[:unix_newlines]

        if @args[1] && !@args[0].include?(':')
          flag = @options[:update] ? "--update" : "--watch"
          err =
            if !File.exist?(@args[1])
              "doesn't exist"
            elsif @args[1] =~ /\.css$/
              "is a CSS file"
            end
          raise <<MSG if err
File #{@args[1]} #{err}.
  Did you mean: sass #{flag} #{@args[0]}:#{@args[1]}
MSG
        end

        dirs, files = @args.map {|name| name.split(':', 2)}.
          map {|from, to| [from, to || from.gsub(/\..*?$/, '.css')]}.
          partition {|i, _| File.directory? i}
        ::Sass::Plugin.options[:template_location] = dirs

        ::Sass::Plugin.on_updating_stylesheet do |_, css|
          if File.exists? css
            puts_action :overwrite, :yellow, css
          else
            puts_action :create, :green, css
          end
        end

        ::Sass::Plugin.on_creating_directory {|dirname| puts_action :directory, :green, dirname}
        ::Sass::Plugin.on_deleting_css {|filename| puts_action :delete, :yellow, filename}
        ::Sass::Plugin.on_compilation_error do |error, _, _|
          raise error unless error.is_a?(::Sass::SyntaxError)
          puts_action :error, :red, "#{error.sass_filename} (Line #{error.sass_line}: #{error.message})"
        end

        if @options[:update]
          ::Sass::Plugin.update_stylesheets(files)
          return
        end

        puts ">>> Sass is watching for changes. Press Ctrl-C to stop."

        ::Sass::Plugin.on_template_modified {|template| puts ">>> Change detected to: #{template}"}
        ::Sass::Plugin.on_template_created {|template| puts ">>> New template detected: #{template}"}
        ::Sass::Plugin.on_template_deleted {|template| puts ">>> Deleted template detected: #{template}"}

        ::Sass::Plugin.watch(files)
      end

      # @private
      COLORS = { :red => 31, :green => 32, :yellow => 33 }

      def puts_action(name, color, arg)
        printf color(color, "%11s %s\n"), name, arg
      end

      def color(color, str)
        raise "[BUG] Unrecognized color #{color}" unless COLORS[color]

        # Almost any real Unix terminal will support color,
        # so we just filter for Windows terms (which don't set TERM)
        # and not-real terminals, which aren't ttys.
        return str if ENV["TERM"].empty? || !STDOUT.tty?
        return "\e[#{COLORS[color]}m#{str}\e[0m"
      end
    end

    # The `haml` executable.
    class Haml < HamlSass
      # @param args [Array<String>] The command-line arguments
      def initialize(args)
        super
        @name = "Haml"
        @options[:requires] = []
        @options[:load_paths] = []
      end

      # Tells optparse how to parse the arguments.
      #
      # @param opts [OptionParser]
      def set_opts(opts)
        super

        opts.on('-t', '--style NAME',
                'Output style. Can be indented (default) or ugly.') do |name|
          @options[:for_engine][:ugly] = true if name.to_sym == :ugly
        end

        opts.on('-f', '--format NAME',
                'Output format. Can be xhtml (default), html4, or html5.') do |name|
          @options[:for_engine][:format] = name.to_sym
        end

        opts.on('-e', '--escape-html',
                'Escape HTML characters (like ampersands and angle brackets) by default.') do
          @options[:for_engine][:escape_html] = true
        end

        opts.on('-q', '--double-quote-attributes',
                'Set attribute wrapper to double-quotes (default is single).') do
          @options[:for_engine][:attr_wrapper] = '"'
        end

        opts.on('-r', '--require FILE', "Same as 'ruby -r'.") do |file|
          @options[:requires] << file
        end

        opts.on('-I', '--load-path PATH', "Same as 'ruby -I'.") do |path|
          @options[:load_paths] << path
        end

        opts.on('--debug', "Print out the precompiled Ruby source.") do
          @options[:debug] = true
        end
      end

      # Processes the options set by the command-line arguments,
      # and runs the Haml compiler appropriately.
      def process_result
        super
        input = @options[:input]
        output = @options[:output]

        template = input.read()
        input.close() if input.is_a? File

        begin
          engine = ::Haml::Engine.new(template, @options[:for_engine])
          if @options[:check_syntax]
            puts "Syntax OK"
            return
          end

          @options[:load_paths].each {|p| $LOAD_PATH << p}
          @options[:requires].each {|f| require f}

          if @options[:debug]
            puts engine.precompiled
            puts '=' * 100
          end

          result = engine.to_html
        rescue Exception => e
          raise e if @options[:trace]

          case e
          when ::Haml::SyntaxError; raise "Syntax error on line #{get_line e}: #{e.message}"
          when ::Haml::Error;       raise "Haml error on line #{get_line e}: #{e.message}"
          else raise "Exception on line #{get_line e}: #{e.message}\n  Use --trace for backtrace."
          end
        end

        output.write(result)
        output.close() if output.is_a? File
      end
    end

    # The `html2haml` executable.
    class HTML2Haml < Generic
      # @param args [Array<String>] The command-line arguments
      def initialize(args)
        super
        @module_opts = {}
      end

      # Tells optparse how to parse the arguments.
      #
      # @param opts [OptionParser]
      def set_opts(opts)
        opts.banner = <<END
Usage: html2haml [options] [INPUT] [OUTPUT]

Description: Transforms an HTML file into corresponding Haml code.

Options:
END

        opts.on('-e', '--erb', 'Parse ERb tags.') do
          @module_opts[:erb] = true
        end

        opts.on('--no-erb', "Don't parse ERb tags.") do
          @options[:no_erb] = true
        end

        opts.on('-r', '--rhtml', 'Deprecated; same as --erb.') do
          @module_opts[:erb] = true
        end

        opts.on('--no-rhtml', "Deprecated; same as --no-erb.") do
          @options[:no_erb] = true
        end

        opts.on('-x', '--xhtml', 'Parse the input using the more strict XHTML parser.') do
          @module_opts[:xhtml] = true
        end

        super
      end

      # Processes the options set by the command-line arguments,
      # and runs the HTML compiler appropriately.
      def process_result
        super

        require 'haml/html'

        input = @options[:input]
        output = @options[:output]

        @module_opts[:erb] ||= input.respond_to?(:path) && input.path =~ /\.(rhtml|erb)$/
        @module_opts[:erb] &&= @options[:no_erb] != false

        output.write(::Haml::HTML.new(input, @module_opts).render)
      rescue ::Haml::Error => e
        raise "#{e.is_a?(::Haml::SyntaxError) ? "Syntax error" : "Error"} on line " +
          "#{get_line e}: #{e.message}"
      rescue LoadError => err
        dep = err.message.scan(/^no such file to load -- (.*)/)[0]
        raise err if @options[:trace] || dep.nil? || dep.empty?
        $stderr.puts "Required dependency #{dep} not found!\n  Use --trace for backtrace."
        exit 1
      end
    end

    # The `css2sass` executable.
    class CSS2Sass < Generic
      # @param args [Array<String>] The command-line arguments
      def initialize(args)
        super
        @module_opts = {}
      end

      # Tells optparse how to parse the arguments.
      #
      # @param opts [OptionParser]
      def set_opts(opts)
        opts.banner = <<END
Usage: css2sass [options] [INPUT] [OUTPUT]

Description: Transforms a CSS file into corresponding Sass code.

Options:
END

        opts.on('--old', 'Output the old-style ":prop val" property syntax') do
          @module_opts[:old] = true
        end

        opts.on_tail('-a', '--alternate', 'Ignored') {}

        super
      end

      # Processes the options set by the command-line arguments,
      # and runs the CSS compiler appropriately.
      def process_result
        super

        require 'sass/css'

        input = @options[:input]
        output = @options[:output]

        output.write(::Sass::CSS.new(input, @module_opts).render)
      rescue ::Sass::SyntaxError => e
        raise e if @options[:trace]
        raise "Syntax error on line #{get_line e}: #{e.message}\n  Use --trace for backtrace"
      end
    end
  end
end
