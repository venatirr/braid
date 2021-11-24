require 'singleton'
require 'rubygems'
require 'tempfile'

module Braid
  require 'open3'

  module Operations
    class ShellExecutionError < BraidError
      attr_reader :err, :out

      def initialize(err = nil, out = nil)
        @err = err
        @out = out
      end

      def message
        @err.to_s.split("\n").first
      end
    end
    class VersionTooLow < BraidError
      def initialize(command, version, required)
        @command  = command
        @version  = version.to_s.split("\n").first
        @required = required
      end

      def message
        "#{@command} version too low: #{@version}. #{@required} needed."
      end
    end
    class UnknownRevision < BraidError
      def message
        "unknown revision: #{super}"
      end
    end
    class LocalChangesPresent < BraidError
      def message
        'local changes are present'
      end
    end
    class MergeError < BraidError
      attr_reader :conflicts_text

      def initialize(conflicts_text)
        @conflicts_text = conflicts_text
      end

      def message
        'could not merge'
      end
    end

    # The command proxy is meant to encapsulate commands such as git, that work with subcommands.
    class Proxy
      include Singleton

      def self.command;
        name.split('::').last.downcase;
      end

      # hax!
      def version
        status, out, err = exec!("#{self.class.command} --version")
        out.sub(/^.* version/, '').strip
      end

      def require_version(required)
        required = required.split('.')
        actual   = version.split('.')

        actual.each_with_index do |actual_piece, idx|
          required_piece = required[idx]

          return true unless required_piece

          case (actual_piece <=> required_piece)
            when -1
              return false
            when 1
              return true
            when 0
              next
          end
        end

        return actual.length >= required.length
      end

      def require_version!(required)
        require_version(required) || raise(VersionTooLow.new(self.class.command, version, required))
      end

      private

      def command(name)
        # stub
        name
      end

      def invoke(arg, *args)
        exec!("#{command(arg)} #{args.join(' ')}".strip)[1].strip # return stdout
      end

      def method_missing(name, *args)
        invoke(name, *args)
      end

      def exec(cmd)
        cmd.strip!

        Operations::with_modified_environment({'LANG' => 'C'}) do
          log(cmd)
          out, err, status = Open3.capture3(cmd)
          [status, out, err]
        end
      end

      def exec!(cmd)
        status, out, err = exec(cmd)
        raise ShellExecutionError.new(err, out) unless status == 0
        [status, out, err]
      end

      def system(cmd)
        cmd.strip!

        # Without this, "braid diff" output came out in the wrong order on Windows.
        $stdout.flush
        $stderr.flush
        Operations::with_modified_environment({'LANG' => 'C'}) do
          Kernel.system(cmd)
          return $?
        end
      end

      def msg(str)
        puts "Braid: #{str}"
      end

      def log(cmd)
        msg "Executing `#{cmd}` in #{Dir.pwd}" if verbose?
      end

      def verbose?
        Braid.verbose
      end
    end

    class Git < Proxy
      # Get the physical path to a file in the git repository (e.g.,
      # 'MERGE_MSG'), taking into account worktree configuration.  The returned
      # path may be absolute or relative to the current working directory.
      def repo_file_path(path)
        if require_version('2.5')  # support for --git-path
          invoke(:rev_parse, '--git-path', path)
        else
          # Git < 2.5 doesn't support linked worktrees anyway.
          File.join(invoke(:rev_parse, '--git-dir'), path)
        end
      end

      # If the current directory is not inside a git repository at all, this
      # command will fail with "fatal: Not a git repository" and that will be
      # propagated as a ShellExecutionError.  is_inside_worktree can return
      # false when inside a bare repository and in certain other rare cases such
      # as when the GIT_WORK_TREE environment variable is set.
      def is_inside_worktree
        invoke(:rev_parse, '--is-inside-work-tree') == 'true'
      end

      # Get the prefix of the current directory relative to the worktree.  Empty
      # string if it's the root of the worktree, otherwise ends with a slash.
      # In some cases in which the current directory is not inside a worktree at
      # all, this will successfully return an empty string, so it may be
      # desirable to check is_inside_worktree first.
      def relative_working_dir
        invoke(:rev_parse, '--show-prefix')
      end

      def commit(message, *args)
        cmd = 'git commit --no-verify'
        if message # allow nil
          message_file = Tempfile.new('braid_commit')
          message_file.print("Braid: #{message}")
          message_file.flush
          message_file.close
          cmd << " -F #{message_file.path}"
        end
        cmd << " #{args.join(' ')}" unless args.empty?
        status, out, err = exec(cmd)
        message_file.unlink if message_file

        if status == 0
          true
        elsif out.match(/nothing.* to commit/)
          false
        else
          raise ShellExecutionError, err
        end
      end

      def fetch(remote = nil, *args)
        args.unshift "-n #{remote}" if remote
        #exec!("git lfs fetch")
        exec!("git fetch #{args.join(' ')}")
      end

      def checkout(treeish)
        invoke(:checkout, treeish)
        true
      end

      # Returns the base commit or nil.
      def merge_base(target, source)
        invoke(:merge_base, target, source)
      rescue ShellExecutionError
        nil
      end

      def rev_parse(opt)
        invoke(:rev_parse, opt)
      rescue ShellExecutionError
        raise UnknownRevision, opt
      end

      # Implies tracking.
      def remote_add(remote, path)
        invoke(:remote, 'add', remote, path)
        true
      end

      def remote_rm(remote)
        invoke(:remote, 'rm', remote)
        true
      end

      # Checks git remotes.
      def remote_url(remote)
        key = "remote.#{remote}.url"
        invoke(:config, key)
      rescue ShellExecutionError
        nil
      end

      def reset_hard(target)
        invoke(:reset, '--hard', target)
        true
      end

      # Merge three trees (local_treeish should match the current state of the
      # index) and update the index and working tree.
      #
      # The usage of 'git merge-recursive' doesn't seem to be officially
      # documented, but it does accept trees.  When a single base is passed, the
      # 'recursive' part (i.e., merge of bases) does not come into play and only
      # the trees matter.  But for some reason, Git's smartest tree merge
      # algorithm is only available via the 'recursive' strategy.
      def merge_trees(base_treeish, local_treeish, remote_treeish)
        invoke(:merge_recursive, base_treeish, "-- #{local_treeish} #{remote_treeish}")
        true
      rescue ShellExecutionError => error
        # 'CONFLICT' messages go to stdout.
        raise MergeError, error.out
      end

      def read_ls_files(prefix)
        invoke('ls-files', prefix)
      end

      class BlobWithMode
        def initialize(hash, mode)
          @hash = hash
          @mode = mode
        end
        attr_reader :hash, :mode
      end
      # Allow the class to be referenced as `git.BlobWithMode`.
      def BlobWithMode
        Git::BlobWithMode
      end

      # Get the item at the given path in the given tree.  If it's a tree, just
      # return its hash; if it's a blob, return a BlobWithMode object.  (This is
      # how we remember the mode for single-file mirrors.)
      def get_tree_item(tree, path)
        if path.nil? || path == ''
          tree
        else
          m = /^([^ ]*) ([^ ]*) ([^\t]*)\t.*$/.match(invoke(:ls_tree, tree, path))
          mode = m[1]
          type = m[2]
          hash = m[3]
          if type == 'tree'
            hash
          elsif type == 'blob'
            return BlobWithMode.new(hash, mode)
          else
            raise ShellExecutionError, 'Tree item is not a tree or a blob'
          end
        end
      end

      # Add the item (as returned by get_tree_item) to the index at the given
      # path.  If update_worktree is true, then update the worktree, otherwise
      # disregard the state of the worktree (most useful with a temporary index
      # file).
      def add_item_to_index(item, path, update_worktree)
        if item.is_a?(BlobWithMode)
          # Our minimum git version is 1.6.0 and the new --cacheinfo syntax
          # wasn't added until 2.0.0.
          invoke(:update_index, '--add', '--cacheinfo', item.mode, item.hash, path)
          if update_worktree
            # XXX If this fails, we've already updated the index.
            invoke(:checkout_index, path)
          end
        else
          # Yes, if path == '', "git read-tree --prefix=/" works. :/
          invoke(:read_tree, "--prefix=#{path}/", update_worktree ? '-u' : '-i', item)
        end
      end

      # Read tree into the root of the index.  This may not be the preferred way
      # to do it, but it seems to work.
      def read_tree_im(treeish)
        invoke(:read_tree, '-im', treeish)
        true
      end

      # Write a tree object for the current index and return its ID.
      def write_tree
        invoke(:write_tree)
      end

      # Execute a block using a temporary git index file, initially empty.
      def with_temporary_index
        Dir.mktmpdir('braid_index') do |dir|
          Operations::with_modified_environment(
            {'GIT_INDEX_FILE' => File.join(dir, 'index')}) do
            yield
          end
        end
      end

      def make_tree_with_item(main_content, item_path, item)
        with_temporary_index do
          if main_content
            read_tree_im(main_content)
            rm_r_cached(item_path)
          end
          add_item_to_index(item, item_path, false)
          write_tree
        end
      end

      def config(args)
        invoke(:config, args) rescue nil
      end

      def rm_r(path)
        invoke(:rm, '-r', path)
        true
      end

      # Remove from index only.
      def rm_r_cached(path)
        invoke(:rm, '-r', '--cached', path)
        true
      end

      def tree_hash(path, treeish = 'HEAD')
        out = invoke(:ls_tree, treeish, '-d', path)
        out.split[2]
      end

      def diff_to_stdout(*args)
        # For now, ignore the exit code.  It can be 141 (SIGPIPE) if the user
        # quits the pager before reading all the output.
        system("git diff #{args.join(' ')}")
      end

      def status_clean?
        status, out, err = exec('git status')
        !out.split("\n").grep(/nothing to commit/).empty?
      end

      def ensure_clean!
        status_clean? || raise(LocalChangesPresent)
      end

      def head
        rev_parse('HEAD')
      end

      def branch
        status, out, err = exec!("git branch | grep '*'")
        out[2..-1]
      end

      def clone(*args)
        # overrides builtin
        invoke(:clone, *args)
      end

      private

      def command(name)
        "#{self.class.command} #{name.to_s.gsub('_', '-')}"
      end
    end

    class GitCache
      include Singleton

      def fetch(url)
        dir = path(url)

        # remove local cache if it was created with --no-checkout
        if File.exists?("#{dir}/.git")
          FileUtils.rm_r(dir)
        end

        if File.exists?(dir)
          Dir.chdir(dir) do
            git.fetch
          end
        else
          FileUtils.mkdir_p(local_cache_dir)
          git.clone('--mirror', url, dir)
        end
      end

      def path(url)
        File.join(local_cache_dir, url.gsub(/[\/:@]/, '_'))
      end

      private

      def local_cache_dir
        Braid.local_cache_dir
      end

      def git
        Git.instance
      end
    end

    module VersionControl
      def git
        Git.instance
      end

      def git_cache
        GitCache.instance
      end
    end
  end
end
