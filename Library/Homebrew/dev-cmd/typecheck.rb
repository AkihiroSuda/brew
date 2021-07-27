# typed: false
# frozen_string_literal: true

require "cli/parser"

module Homebrew
  extend T::Sig

  module_function

  sig { returns(CLI::Parser) }
  def typecheck_args
    Homebrew::CLI::Parser.new do
      description <<~EOS
        Check for typechecking errors using Sorbet.

        Not (yet) working on Apple Silicon.
      EOS
      switch "--fix",
             description: "Automatically fix type errors."
      switch "-q", "--quiet",
             description: "Silence all non-critical errors."
      switch "--update",
             description: "Update RBI files."
      switch "--suggest-typed",
             depends_on:  "--update",
             description: "Try upgrading `typed` sigils."
      switch "--fail-if-not-changed",
             description: "Return a failing status code if all gems are up to date " \
                          "and gem definitions do not need a tapioca update."
      flag   "--dir=",
             description: "Typecheck all files in a specific directory."
      flag   "--file=",
             description: "Typecheck a single file."
      flag   "--ignore=",
             description: "Ignores input files that contain the given string " \
                          "in their paths (relative to the input path passed to Sorbet)."

      conflicts "--dir", "--file"

      named_args :none
    end
  end

  sig { void }
  def typecheck
    # TODO: update description above if removing this.
    if Hardware::CPU.arm? || Hardware::CPU.in_rosetta2?
      raise UsageError, "not (yet) working on Apple Silicon or Rosetta 2!"
    end

    args = typecheck_args.parse

    Homebrew.install_bundler_gems!(groups: ["sorbet"])

    HOMEBREW_LIBRARY_PATH.cd do
      if args.update?
        excluded_gems = [
          "did_you_mean", # RBI file is already provided by Sorbet
        ]

        ohai "Updating Tapioca RBI files..."
        system "bundle", "exec", "tapioca", "sync", "--exclude", *excluded_gems
        system "bundle", "exec", "parlour"
        system "bundle", "exec", "srb", "rbi", "hidden-definitions"
        system "bundle", "exec", "srb", "rbi", "todo"

        if args.suggest_typed?
          result = system_command(
            "bundle",
            args:         ["exec", "--", "srb", "tc", "--suggest-typed", "--typed=strict",
                           "--isolate-error-code=7022"],
            print_stderr: false,
          )

          allowed_changes = {
            "false" => ["true", "strict"],
            "true"  => ["strict"],
          }

          # Workaround for `srb tc rbi suggest-typed`, which currently fails get to a converging state.
          result.stderr.scan(/^(.*\.rb):\d+:\s+You could add `#\s*typed:\s*(.*?)`/).each do |path, new_level|
            path = Pathname(path)

            next unless path.file?

            contents = path.read

            next unless (match = contents.match(/\A\s*#\s*typed:\s*([^\s]+)/))

            existing_level = match[1]

            next unless allowed_changes.fetch(existing_level, []).include?(new_level)

            puts "#{path}: #{existing_level} -> #{new_level}"
            path.atomic_write contents.sub(/\A(\s*#\s*typed:\s*)(?:[^\s]+)/, "\\1#{new_level}")
          end
        end

        Homebrew.failed = system("git", "diff", "--stat", "--exit-code") if args.fail_if_not_changed?

        return
      end

      srb_exec = %w[bundle exec srb tc]

      # TODO: comment explaining why?
      srb_exec << "--suppress-error-code" << "5061"

      srb_exec << "--quiet" if args.quiet?

      if args.fix?
        # Auto-correcting method names is almost always wrong.
        srb_exec << "--suppress-error-code" << "7003"

        srb_exec << "--autocorrect"
      end

      srb_exec += ["--ignore", args.ignore] if args.ignore.present?
      if args.file.present? || args.dir.present?
        cd("sorbet")
        srb_exec += ["--file", "../#{args.file}"] if args.file
        srb_exec += ["--dir", "../#{args.dir}"] if args.dir
      end
      success = system(*srb_exec)
      return if success

      $stderr.puts "Check #{Formatter.url("https://docs.brew.sh/Typechecking")} for " \
                   "more information on how to resolve these errors."
      Homebrew.failed = true
    end
  end
end
