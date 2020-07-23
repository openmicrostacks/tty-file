# frozen_string_literal: true

require "pastel"
require "erb"
require "tempfile"
require "pathname"

require_relative "file/create_file"
require_relative "file/digest_file"
require_relative "file/download_file"
require_relative "file/differ"
require_relative "file/read_backward_file"
require_relative "file/version"

module TTY
  module File
    def self.private_module_function(method)
      module_function(method)
      private_class_method(method)
    end
    # Invalid path erorr
    InvalidPathError = Class.new(ArgumentError)

    # File permissions
    U_R = 0400
    U_W = 0200
    U_X = 0100
    G_R = 0040
    G_W = 0020
    G_X = 0010
    O_R = 0004
    O_W = 0002
    O_X = 0001
    A_R = 0444
    A_W = 0222
    A_X = 0111

    # Check if file is binary
    #
    # @param [String, Pathname] relative_path
    #   the path to file to check
    #
    # @example
    #   binary?("Gemfile") # => false
    #
    # @example
    #   binary?("image.jpg") # => true
    #
    # @return [Boolean]
    #   Returns `true` if the file is binary, `false` otherwise
    #
    # @api public
    def binary?(relative_path)
      bytes = ::File.new(relative_path).size
      bytes = 2**12 if bytes > 2**12
      buffer = read_to_char(relative_path, bytes, 0)

      begin
        buffer !~ /\A[\s[[:print:]]]*\z/m
      rescue ArgumentError => error
        return true if error.message =~ /invalid byte sequence/
        raise
      end
    end
    module_function :binary?

    # Read bytes from a file up to valid character
    #
    # @param [String, Pathname] relative_path
    #   the path to file
    #
    # @param [Integer] bytes
    #
    # @example
    #   TTY::File.read_to_char()
    #
    # @return [String]
    #
    # @api public
    def read_to_char(relative_path, bytes = nil, offset = nil)
      buffer = ""
      ::File.open(relative_path) do |file|
        buffer = file.read(bytes) || ""
        buffer = buffer.dup.force_encoding(Encoding.default_external)

        while !file.eof? && !buffer.valid_encoding? &&
              (buffer.bytesize < bytes + 10)

          buffer += file.read(1).force_encoding(Encoding.default_external)
        end
      end
      buffer
    end
    module_function :read_to_char

    # Create checksum for a file, io or string objects
    #
    # @param [File, IO, String, Pathname] source
    #   the source to generate checksum for
    # @param [String] mode
    # @param [Hash[Symbol]] options
    # @option options [String] :noop
    #   No operation
    #
    # @example
    #   checksum_file("/path/to/file")
    #
    # @example
    #   checksum_file("Some string content", "md5")
    #
    # @return [String]
    #   the generated hex value
    #
    # @api public
    def checksum_file(source, *args, noop: false)
      mode     = args.size.zero? ? "sha256" : args.pop
      digester = DigestFile.new(source, mode)
      digester.call unless noop
    end
    module_function :checksum_file

    # Change file permissions
    #
    # @param [String, Pathname] relative_path
    # @param [Integer,String] permisssions
    # @param [Hash[Symbol]] options
    # @option options [Symbol] :noop
    # @option options [Symbol] :verbose
    # @option options [Symbol] :force
    #
    # @example
    #   chmod("Gemfile", 0755)
    #
    # @example
    #   chmod("Gemilfe", TTY::File::U_R | TTY::File::U_W)
    #
    # @example
    #   chmod("Gemfile", "u+x,g+x")
    #
    # @api public
    def chmod(relative_path, permissions, verbose: true, color: :green, noop: false)
      log_status(:chmod, relative_path, verbose: verbose, color: color)
      ::FileUtils.chmod_R(permissions, relative_path) unless noop
    end
    module_function :chmod

    # Create directory structure
    #
    # @param [String, Pathname, Hash] destination
    #   the path or data structure describing directory tree
    #
    # @example
    #   create_directory("/path/to/dir")
    #
    # @example
    #   tree =
    #     "app" => [
    #       "README.md",
    #       ["Gemfile", "gem "tty-file""],
    #       "lib" => [
    #         "cli.rb",
    #         ["file_utils.rb", "require "tty-file""]
    #       ]
    #       "spec" => []
    #     ]
    #
    #   create_directory(tree)
    #
    # @return [void]
    #
    # @api public
    def create_directory(destination, *args, context: nil, verbose: true,
                         color: :green, noop: false, force: false, skip: false)
      parent = args.size.nonzero? ? args.pop : nil
      if destination.is_a?(String) || destination.is_a?(Pathname)
        destination = { destination.to_s => [] }
      end

      destination.each do |dir, files|
        path = parent.nil? ? dir : ::File.join(parent, dir)
        unless ::File.exist?(path)
          ::FileUtils.mkdir_p(path)
          log_status(:create, path, verbose: verbose, color: color)
        end

        files.each do |filename, contents|
          if filename.respond_to?(:each_pair)
            create_directory(filename, path, context: context,
                             verbose: verbose, color: color, noop: noop,
                             force: force, skip: skip)
          else
            create_file(::File.join(path, filename), contents, context: context,
                        verbose: verbose, color: color, noop: noop, force: force,
                        skip: skip)
          end
        end
      end
    end
    module_function :create_directory

    alias create_dir create_directory
    module_function :create_dir

    # Create new file if doesn't exist
    #
    # @param [String, Pathname] relative_path
    # @param [String|nil] content
    #   the content to add to file
    # @param [Symbol] :context
    #   the binding to use for the template
    # @param [Symbol] :force
    #   forces ovewrite if conflict present
    # @param [Symbol] :verbose
    #   If true log the action status to stdout
    # @param [Symbol] :noop
    #   If true do not execute the action.
    # @param [Symbol] :skip
    #   If true skip the action.
    #
    # @example
    #   create_file("doc/README.md", "# Title header")
    #
    # @example
    #   create_file "doc/README.md" do
    #     "# Title Header"
    #   end
    #
    # @api public
    def create_file(relative_path, *args, context: nil, force: false, skip: false,
                    verbose: true, color: :green, noop: false, &block)
      relative_path = relative_path.to_s
      content = block_given? ? block[] : args.join

      CreateFile.new(self, relative_path, content, context: context, force: force,
                     skip: skip, verbose: verbose, color: color, noop: noop).call
    end
    module_function :create_file

    alias add_file create_file
    module_function :add_file

    # Copy file from the relative source to the relative
    # destination running it through ERB.
    #
    # @example
    #   copy_file "templates/test.rb", "app/test.rb"
    #
    # @example
    #   vars = OpenStruct.new
    #   vars[:name] = "foo"
    #   copy_file "templates/%name%.rb", "app/%name%.rb", context: vars
    #
    # @param [String, Pathname] source_path
    #   the file path to copy file from
    # @param [Symbol] :context
    #   the binding to use for the template
    # @param [Symbol] :preserve
    #   If true, the owner, group, permissions and modified time
    #   are preserved on the copied file, defaults to false.
    # @param [Symbol] :noop
    #   If true do not execute the action.
    # @param [Symbol] :verbose
    #   If true log the action status to stdout
    #
    # @api public
    def copy_file(source_path, *args, context: nil, force: false, skip: false,
                  verbose: true, color: :green, noop: false, preserve: nil, &block)
      source_path = source_path.to_s
      dest_path = (args.first || source_path).to_s.sub(/\.erb$/, "")

      ctx = if context
              context.instance_eval("binding")
            else
              instance_eval("binding")
            end

      create_file(dest_path, context: context, force: force, skip: skip,
                  verbose: verbose, color: color, noop: noop) do
        version = ERB.version.scan(/\d+\.\d+\.\d+/)[0]
        template = if version.to_f >= 2.2
                    ERB.new(::File.binread(source_path), trim_mode: "-", eoutvar: "@output_buffer")
                   else
                    ERB.new(::File.binread(source_path), nil, "-", "@output_buffer")
                   end
        content = template.result(ctx)
        content = block[content] if block
        content
      end
      return unless preserve

      copy_metadata(source_path, dest_path, verbose: verbose, noop: noop,
                    color: color)
    end
    module_function :copy_file

    # Copy file metadata
    #
    # @param [String] src_path
    #   the source file path
    # @param [String] dest_path
    #   the destination file path
    #
    # @api public
    def copy_metadata(src_path, dest_path, **options)
      stats = ::File.lstat(src_path)
      ::File.utime(stats.atime, stats.mtime, dest_path)
      chmod(dest_path, stats.mode, **options)
    end
    module_function :copy_metadata

    # Copy directory recursively from source to destination path
    #
    # Any files names wrapped within % sign will be expanded by
    # executing corresponding method and inserting its value.
    # Assuming the following directory structure:
    #
    #  app/
    #    %name%.rb
    #    command.rb.erb
    #    README.md
    #
    #  Invoking:
    #    copy_directory("app", "new_app")
    #  The following directory structure should be created where
    #  name resolves to "cli" value:
    #
    #  new_app/
    #    cli.rb
    #    command.rb
    #    README
    #
    # @param [String, Pathname] source_path
    #    the source directory to copy files from
    # @param [Symbol] :preserve
    #   If true, the owner, group, permissions and modified time
    #   are preserved on the copied file, defaults to false.
    # @param [Symbol] :recursive
    #   If false, copies only top level files, defaults to true.
    # @param [Symbol] :exclude
    #   A regex that specifies files to ignore when copying.
    #
    # @example
    #   copy_directory("app", "new_app", recursive: false)
    #   copy_directory("app", "new_app", exclude: /docs/)
    #
    # @api public
    def copy_directory(source_path, *args, context: nil, force: false, skip: false,
                       verbose: true, color: :green, noop: false, preserve: nil,
                       recursive: true, exclude: nil, &block)
      source_path = source_path.to_s
      check_path(source_path)
      source = escape_glob_path(source_path)
      dest_path = (args.first || source).to_s
      pattern = recursive ? ::File.join(source, "**") : source
      glob_pattern = ::File.join(pattern, "*")

      Dir.glob(glob_pattern, ::File::FNM_DOTMATCH).sort.each do |file_source|
        next if ::File.directory?(file_source)
        next if exclude && file_source.match(exclude)

        dest = ::File.join(dest_path, file_source.gsub(source_path, "."))
        file_dest = ::Pathname.new(dest).cleanpath.to_s

        copy_file(file_source, file_dest, context: context, force: force,
                  skip: skip, verbose: verbose, color: color, noop: noop,
                  preserve: preserve, &block)
      end
    end
    module_function :copy_directory

    alias copy_dir copy_directory
    module_function :copy_dir

    # Diff files line by line
    #
    # @param [String, Pathname] path_a
    #   the path to the original file
    # @param [String, Pathname] path_b
    #   the path to a new file
    # @param [Symbol] :format
    #   the diffining output format
    # @param [Symbol] :context_lines
    #   the number of extra lines for the context
    # @param [Symbol] :threshold
    #   maximum file size in bytes
    #
    # @example
    #   diff(file_a, file_b, format: :old)
    #
    # @api public
    def diff(path_a, path_b, threshold: 10_000_00, format: :unified,
             header: true, context_lines: 3, verbose: true,
             color: :green, noop: false)
      output = []

      open_tempfile_if_missing(path_a) do |file_a, temp_a|
        check_binary_or_large(file_a, threshold)

        open_tempfile_if_missing(path_b) do |file_b, temp_b|
          check_binary_or_large(file_b, threshold)
          file_a_path = temp_a ? "Old contents" : relative_path(file_a.path)
          file_b_path = temp_b ? "New contents" : relative_path(file_b.path)

          log_status(:diff, "#{file_a_path} and #{file_b_path}",
                     verbose: verbose, color: color)
          return "" if noop

          differ = Differ.new(format: format, context_lines: context_lines)
          block_size = file_a.lstat.blksize
          file_a_chunk = file_a.read(block_size)
          file_b_chunk = file_b.read(block_size)
          hunks = differ.(file_a_chunk, file_b_chunk)

          return "" if file_a_chunk.empty? && file_b_chunk.empty?
          return "No differences found\n" if hunks.empty?

          if %i[unified context old].include?(format) && header
            output << "#{differ.delete_char * 3} #{file_a_path}\n"
            output << "#{differ.add_char * 3} #{file_b_path}\n"
          end

          output << hunks
          while !file_a.eof? && !file_b.eof?
            output << differ.(file_a.read(block_size), file_b.read(block_size))
          end
        end
      end
      output.join
    end
    module_function :diff

    # Check if file is binary or exceeds threshold size
    #
    # @api private
    def check_binary_or_large(file, threshold)
      if binary?(file)
        raise ArgumentError, "(#{file.path} is binary, diff output suppressed)"
      elsif ::File.size(file) > threshold
        raise ArgumentError, "(file size of #{file.path} exceeds #{threshold} " \
                             "bytes, diff output suppressed)"
      end
    end
    private_module_function :check_binary_or_large

    alias diff_files diff
    module_function :diff_files

    # Download the content from a given address and
    # save at the given relative destination. If block
    # is provided in place of destination, the content of
    # of the uri is yielded.
    #
    # @param [String, Pathname] uri
    #   the URI address
    # @param [String, Pathname] dest
    #   the relative path to save
    # @param [Symbol] :limit
    #   the limit of redirects
    #
    # @example
    #   download_file("https://gist.github.com/4701967",
    #                 "doc/benchmarks")
    #
    # @example
    #   download_file("https://gist.github.com/4701967") do |content|
    #     content.gsub("\n", " ")
    #   end
    #
    # @api public
    def download_file(uri, *args, **options, &block)
      uri = uri.to_s
      dest_path = (args.first || ::File.basename(uri)).to_s

      unless uri =~ %r{^https?\://}
        copy_file(uri, dest_path, **options)
        return
      end

      content = DownloadFile.new(uri, dest_path, limit: options[:limit]).call

      if block_given?
        content = (block.arity.nonzero? ? block[content] : block[])
      end

      create_file(dest_path, content, **options)
    end
    module_function :download_file

    alias get_file download_file
    module_function :get_file

    # Prepend to a file
    #
    # @param [String, Pathname] relative_path
    # @param [Array[String]] content
    #   the content to preped to file
    #
    # @example
    #   prepend_to_file("Gemfile", "gem "tty"")
    #
    # @example
    #   prepend_to_file("Gemfile") do
    #     "gem 'tty'"
    #   end
    #
    # @api public
    def prepend_to_file(relative_path, *args, verbose: true, color: :green,
                        force: true, noop: false, &block)
      log_status(:prepend, relative_path, verbose: verbose, color: color)
      inject_into_file(relative_path, *args, before: /\A/, verbose: false,
                       color: color, force: force, noop: noop, &block)
    end
    module_function :prepend_to_file

    # Safely prepend to file checking if content is not already present
    #
    # @api public
    def safe_prepend_to_file(relative_path, *args, **options, &block)
      prepend_to_file(relative_path, *args, **(options.merge(force: false)), &block)
    end
    module_function :safe_prepend_to_file

    # Append to a file
    #
    # @param [String, Pathname] relative_path
    # @param [Array[String]] content
    #   the content to append to file
    #
    # @example
    #   append_to_file("Gemfile", "gem 'tty'")
    #
    # @example
    #   append_to_file("Gemfile") do
    #     "gem 'tty'"
    #   end
    #
    # @api public
    def append_to_file(relative_path, *args, verbose: true, color: :green,
                       force: true, noop: false, &block)
      log_status(:append, relative_path, verbose: verbose, color: color)
      inject_into_file(relative_path, *args, after: /\z/, verbose: false,
                       force: force, noop: noop, color: color, &block)
    end
    module_function :append_to_file

    alias add_to_file append_to_file
    module_function :add_to_file

    # Safely append to file checking if content is not already present
    #
    # @api public
    def safe_append_to_file(relative_path, *args, **options, &block)
      append_to_file(relative_path, *args, **(options.merge(force: false)), &block)
    end
    module_function :safe_append_to_file

    # Inject content into file at a given location
    #
    # @param [String, Pathname] relative_path
    #
    # @param [Hash] options
    # @option options [Symbol] :before
    #   the matching line to insert content before
    # @option options [Symbol] :after
    #   the matching line to insert content after
    # @option options [Symbol] :force
    #   insert content more than once
    # @option options [Symbol] :verbose
    #   log status
    #
    # @example
    #   inject_into_file("Gemfile", "gem 'tty'", after: "gem 'rack'\n")
    #
    # @example
    #   inject_into_file("Gemfile", "gem 'tty'\n", "gem 'loaf'", after: "gem 'rack'\n")
    #
    # @example
    #   inject_into_file("Gemfile", after: "gem 'rack'\n") do
    #     "gem 'tty'\n"
    #   end
    #
    # @api public
    def inject_into_file(relative_path, *args, verbose: true, color: :green,
                         after: nil, before: nil, force: true, noop: false, &block)
      check_path(relative_path)
      replacement = block_given? ? block[] : args.join

      flag, match = after ? [:after, after] : [:before, before]

      match = match.is_a?(Regexp) ? match : Regexp.escape(match)
      content = if flag == :after
                  '\0' + replacement
                else
                  replacement + '\0'
                end

      log_status(:inject, relative_path, verbose: verbose, color: color)
      replace_in_file(relative_path, /#{match}/, content, verbose: false,
                      color: color, force: force, noop: noop)
    end
    module_function :inject_into_file

    alias insert_into_file inject_into_file
    module_function :insert_into_file

    # Safely prepend to file checking if content is not already present
    #
    # @api public
    def safe_inject_into_file(relative_path, *args, **options, &block)
      inject_into_file(relative_path, *args, **(options.merge(force: false)), &block)
    end
    module_function :safe_inject_into_file

    # Replace content of a file matching string, returning false
    # when no substitutions were performed, true otherwise.
    #
    # @param [String, Pathname] relative_path
    # @options [Hash[String]] options
    # @option options [Symbol] :force
    #   replace content even if present
    # @option options [Symbol] :verbose
    #   log status
    #
    # @example
    #   replace_in_file("Gemfile", /gem 'rails'/, "gem 'hanami'")
    #
    # @example
    #   replace_in_file("Gemfile", /gem 'rails'/) do |match|
    #     match = "gem 'hanami'"
    #   end
    #
    # @return [Boolean]
    #   true when replaced content, false otherwise
    #
    # @api public
    def replace_in_file(relative_path, *args, verbose: true, color: :green,
                        noop: false, force: true, &block)
      check_path(relative_path)
      contents = ::File.read(relative_path)
      replacement = (block ? block[] : args[1..-1].join).gsub('\0', "")
      match = Regexp.escape(replacement)
      status = nil

      log_status(:replace, relative_path, verbose: verbose, color: color)
      return false if noop

      if force || !(contents =~ /^#{match}(\r?\n)*/m)
        status = contents.gsub!(*args, &block)
        if !status.nil?
          ::File.open(relative_path, "w") do |file|
            file.write(contents)
          end
        end
      end
      !status.nil?
    end
    module_function :replace_in_file

    alias gsub_file replace_in_file
    module_function :gsub_file

    # Remove a file or a directory at specified relative path.
    #
    # @param [String, Pathname] relative_path
    # @param [Hash[:Symbol]] options
    # @option options [Symbol] :noop
    #   pretend removing file
    # @option options [Symbol] :force
    #   remove file ignoring errors
    # @option options [Symbol] :verbose
    #   log status
    # @option options [Symbol] :secure
    #   for secure removing
    #
    # @example
    #   remove_file "doc/README.md"
    #
    # @api public
    def remove_file(relative_path, *args, verbose: true, color: :red, noop: false,
                    force: nil, secure: true)
      relative_path = relative_path.to_s
      log_status(:remove, relative_path, verbose: verbose, color: color)

      return if noop || !::File.exist?(relative_path)

      ::FileUtils.rm_r(relative_path, force: force, secure: secure)
    end
    module_function :remove_file

    # Provide the last number of lines from a file
    #
    # @param [String, Pathname] relative_path
    #   the relative path to a file
    #
    # @param [Integer] num_lines
    #   the number of lines to return from file
    #
    # @example
    #   tail_file "filename"
    #   # =>  ["line 19", "line20", ... ]
    #
    # @example
    #   tail_file "filename", lines: 15
    #   # =>  ["line 19", "line20", ... ]
    #
    # @return [Array[String]]
    #
    # @api public
    def tail_file(relative_path, lines: 10, chunk_size: 512, &block)
      file = ::File.open(relative_path)
      line_sep = $/
      output = []
      newline_count = 0

      ReadBackwardFile.new(file, chunk_size).each_chunk do |chunk|
        # look for newline index counting from right of chunk
        while (nl_index = chunk.rindex(line_sep, (nl_index || chunk.size) - 1))
          newline_count += 1
          break if newline_count > lines || nl_index.zero?
        end

        if newline_count > lines
          output.insert(0, chunk[(nl_index + 1)..-1])
          break
        else
          output.insert(0, chunk)
        end
      end

      output.join.split(line_sep).each(&block).to_a
    end
    module_function :tail_file

    # Escape glob character in a path
    #
    # @param [String] path
    #   the path to escape
    #
    # @example
    #   escape_glob_path("foo[bar]") => "foo\\[bar\\]"
    #
    # @return [String]
    #
    # @api public
    def escape_glob_path(path)
      path.gsub(/[\\\{\}\[\]\*\?]/) { |x| "\\" + x }
    end
    module_function :escape_glob_path

    # Check if path exists
    #
    # @param [String] path
    #
    # @raise [ArgumentError]
    #
    # @api private
    def check_path(path)
      return if ::File.exist?(path)

      raise InvalidPathError, "File path \"#{path}\" does not exist."
    end
    private_module_function :check_path

    # Change absolute path to relative
    #
    # @param [String] path
    #
    # @api private
    def relative_path(path)
      path = Pathname(path)
      return path if path.relative?
      path.relative_path_from(Pathname.pwd)
    end
    private_module_function :relative_path


    @output = $stdout
    @pastel = Pastel.new(enabled: true)

    def decorate(message, color)
      @pastel.send(color, message)
    end
    private_module_function :decorate

    # Log file operation
    #
    # @api private
    def log_status(cmd, message, verbose: true, color: false)
      return unless verbose

      cmd = cmd.to_s.rjust(12)
      if color
        i = cmd.index(/[a-z]/)
        cmd = cmd[0...i] + decorate(cmd[i..-1], color)
      end

      message = "#{cmd}  #{message}"
      message += "\n" unless message.end_with?("\n")

      @output.print(message)
      @output.flush
    end
    private_module_function :log_status

    # If content is not a path to a file, create a
    # tempfile and open it instead.
    #
    # @param [String] object
    #   a path to file or content
    #
    # @api private
    def open_tempfile_if_missing(object, &block)
      if ::FileTest.file?(object)
        ::File.open(object, &block)
      else
        tempfile = Tempfile.new("tty-file-diff")
        tempfile << object
        tempfile.rewind

        block[tempfile, ::File.basename(tempfile)]

        unless tempfile.nil?
          tempfile.close
          tempfile.unlink
        end
      end
    end
    private_module_function :open_tempfile_if_missing
  end # File
end # TTY
