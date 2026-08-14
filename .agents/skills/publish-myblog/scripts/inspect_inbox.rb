#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "time"
require "uri"

class InboxInspector
  IMAGE_PATTERN = /!\[([^\]]*)\]\(([^)]+)\)/

  def initialize(repo:, inbox: nil)
    @repo = Pathname(repo).expand_path.cleanpath
    @inbox = Pathname(inbox || @repo.join(".myblog", "inbox")).expand_path.cleanpath
  end

  def inspect(title: nil, modified_on: nil)
    candidates = candidate_paths.map { |path| inspect_bundle(path) }
    candidates.select! { |candidate| candidate.fetch("title") == normalize(title) } if title
    if modified_on
      candidates.select! do |candidate|
        Time.iso8601(candidate.fetch("modified_at")).getlocal.to_date == modified_on
      end
    end

    {
      "repo" => @repo.to_s,
      "inbox" => @inbox.to_s,
      "allowed_categories" => allowed_categories,
      "git" => git_state,
      "candidate_count" => candidates.length,
      "candidates" => candidates
    }
  end

  def record(bundle:, post:, commit:, url:)
    candidate = inspect_bundle(checked_bundle_path(bundle))
    post_path = Pathname(post).expand_path.cleanpath
    relative_post = relative_repo_path(post_path)
    raise ArgumentError, "post must be below _posts/" unless relative_post.start_with?("_posts/")
    raise ArgumentError, "post does not exist: #{post_path}" unless post_path.file?

    head = git_output("rev-parse", "HEAD").strip
    raise ArgumentError, "commit is not current HEAD" unless head == commit
    git_output("cat-file", "-e", "#{commit}:#{relative_post}")

    receipt = {
      "source" => relative_repo_path(Pathname(candidate.fetch("path"))),
      "title" => candidate.fetch("title"),
      "content_sha256" => candidate.fetch("content_sha256"),
      "post" => relative_post,
      "commit" => commit,
      "url" => url,
      "published_at" => Time.now.iso8601
    }

    data = load_receipts
    unless data.any? { |entry| entry.fetch("commit", nil) == commit }
      data << receipt
      write_receipts(data)
    end
    { "recorded" => receipt, "receipt_file" => receipt_path.to_s }
  end

  private

  def candidate_paths
    return [] unless @inbox.directory?

    @inbox.children
      .select { |path| path.directory? && path.extname.downcase == ".textbundle" }
      .sort_by { |path| path.basename.to_s.unicode_normalize(:nfc) }
  end

  def checked_bundle_path(path)
    candidate = Pathname(path).expand_path.cleanpath
    raise ArgumentError, "bundle must be a .textbundle directory" unless candidate.directory? && candidate.extname.downcase == ".textbundle"
    raise ArgumentError, "bundle must be inside #{@inbox}" unless inside?(candidate, @inbox)
    raise ArgumentError, "bundle may not be a symlink: #{candidate}" if candidate.symlink?

    candidate
  end

  def inspect_bundle(path)
    path = checked_bundle_path(path)
    text_path = path.join("text.md")
    raise ArgumentError, "TextBundle is missing text.md: #{path}" unless text_path.file?
    raise ArgumentError, "TextBundle text.md may not be a symlink: #{path}" if text_path.symlink?

    markdown = text_path.read(encoding: "UTF-8").gsub("\r\n", "\n")
    parsed = parse_markdown(markdown)
    assets_directory = path.join("assets")
    asset_files = if assets_directory.directory? && !assets_directory.symlink?
                    assets_directory.glob("**/*").select { |entry| entry.file? && !entry.symlink? }.sort
                  else
                    []
                  end
    diagnostics = inspect_images(path, markdown, asset_files)
    source_path = relative_repo_path(path)
    receipts = load_receipts.select do |entry|
      entry["content_sha256"] == bundle_hash(path) || entry["source"] == source_path || entry["title"] == parsed.fetch("title")
    end

    {
      "path" => path.to_s,
      "source" => source_path,
      "title" => parsed.fetch("title"),
      "description" => parsed.fetch("description"),
      "slug" => slugify(parsed.fetch("title")),
      "modified_at" => latest_mtime(path).iso8601,
      "content_sha256" => bundle_hash(path),
      "asset_count" => asset_files.length,
      "asset_bytes" => asset_files.sum(&:size),
      "images" => diagnostics,
      "headings" => parsed.fetch("headings"),
      "existing_posts" => existing_posts(parsed.fetch("title"), slugify(parsed.fetch("title"))),
      "receipts" => receipts
    }
  end

  def parse_markdown(markdown)
    lines = markdown.lines
    first_index = lines.index { |line| !line.strip.empty? }
    heading = first_index && lines.fetch(first_index).match(/^#\s+(.+?)\s*$/)
    raise ArgumentError, "first non-empty line must be an H1" unless heading

    title = normalize(heading[1])
    body_lines = lines.each_with_index.reject { |_line, index| index == first_index }.map(&:first)
    body = body_lines.join.sub(/\A\s+/, "")
    description = first_text_paragraph(body)
    raise ArgumentError, "article needs a text paragraph below the title" if description.empty?

    headings = []
    previous_level = 1
    body_lines.each_with_index do |line, index|
      match = line.match(/^(#+)\s+(.+?)\s*$/)
      next unless match

      level = match[1].length
      headings << {
        "line" => index + 1,
        "level" => level,
        "text" => normalize(match[2]),
        "body_h1" => level == 1,
        "jump" => level > previous_level + 1
      }
      previous_level = level
    end

    { "title" => title, "description" => description, "headings" => headings }
  end

  def first_text_paragraph(markdown)
    paragraph = markdown.split(/\n\s*\n/).map(&:strip).find do |candidate|
      !candidate.empty? && !candidate.start_with?("#", "!", "```", "~~~")
    end
    return "" unless paragraph

    paragraph
      .gsub(/^>\s?/, "")
      .gsub(IMAGE_PATTERN, "")
      .gsub(/\[([^\]]+)\]\([^)]+\)/, "\\1")
      .gsub(/[*_`~]/, "")
      .gsub(/\s+/, " ")
      .strip
  end

  def inspect_images(bundle, markdown, asset_files)
    assets_root = bundle.join("assets").cleanpath
    references = []
    markdown.each_line.with_index(1) do |line, line_number|
      line.scan(IMAGE_PATTERN) do |alt, source|
        decoded = URI::DEFAULT_PARSER.unescape(source).sub(/\A<|>\z/, "")
        kind = if decoded.match?(/\Ahttps?:\/\//i) || decoded.start_with?("//")
                 "remote"
               elsif decoded.start_with?("assets/")
                 "local"
               else
                 "unsupported"
               end
        entry = { "line" => line_number, "alt" => alt.strip, "source" => source, "kind" => kind }
        if kind == "local"
          source_path = bundle.join(decoded).cleanpath
          entry["path_safe"] = inside?(source_path, assets_root)
          entry["symlinked"] = entry["path_safe"] && symlinked_path?(source_path, bundle)
          entry["exists"] = entry["path_safe"] && !entry["symlinked"] && source_path.file?
          entry["normalized_name"] = safe_asset_name(source_path.basename.to_s)
          entry["sha256"] = Digest::SHA256.file(source_path).hexdigest if entry["exists"]
        end
        references << entry
      end
    end

    local = references.select { |entry| entry["kind"] == "local" }
    referenced_paths = local.filter_map do |entry|
      next unless entry["path_safe"]

      bundle.join(URI::DEFAULT_PARSER.unescape(entry.fetch("source")).sub(/\A<|>\z/, "")).cleanpath.to_s
    end
    normalized_collisions = local
      .select { |entry| entry["normalized_name"] }
      .group_by { |entry| entry["normalized_name"] }
      .select { |_name, entries| entries.map { |entry| entry["source"] }.uniq.length > 1 }
      .keys
    duplicate_hashes = local
      .select { |entry| entry["sha256"] }
      .group_by { |entry| entry["sha256"] }
      .select { |_hash, entries| entries.map { |entry| entry["source"] }.uniq.length > 1 }
      .keys

    {
      "references" => references,
      "empty_alt_lines" => references.select { |entry| entry["alt"].empty? }.map { |entry| entry["line"] },
      "missing_local_sources" => local.reject { |entry| entry["exists"] }.map { |entry| entry["source"] },
      "unsafe_local_sources" => local.reject { |entry| entry["path_safe"] }.map { |entry| entry["source"] },
      "remote_sources" => references.select { |entry| entry["kind"] == "remote" }.map { |entry| entry["source"] },
      "unsupported_sources" => references.select { |entry| entry["kind"] == "unsupported" }.map { |entry| entry["source"] },
      "normalized_name_collisions" => normalized_collisions,
      "duplicate_content_sha256" => duplicate_hashes,
      "unreferenced_assets" => asset_files.reject { |asset| referenced_paths.include?(asset.cleanpath.to_s) }.map { |asset| asset.relative_path_from(bundle).to_s },
      "symlinks" => bundle.glob("**/*", File::FNM_DOTMATCH).select(&:symlink?).map { |entry| entry.relative_path_from(bundle).to_s }
    }
  end

  def allowed_categories
    @repo.join("_posts").glob("*.md").flat_map do |path|
      lines = front_matter_lines(path)
      index = lines.index { |line| line.match?(/^categories:\s*$/) }
      next [] unless index

      lines[(index + 1)..].take_while { |line| line.match?(/^\s+-\s+/) }.map do |line|
        yaml_scalar(line.sub(/^\s+-\s+/, "").strip)
      end
    end.compact.uniq.sort
  end

  def existing_posts(title, slug)
    @repo.join("_posts").glob("*.md").filter_map do |path|
      fields = front_matter_fields(path)
      post_title = fields["title"]
      permalink = fields["permalink"]
      next unless post_title == title || permalink == "/posts/#{slug}/"

      relative_repo_path(path)
    end.sort
  end

  def front_matter_lines(path)
    lines = path.readlines(encoding: "UTF-8")
    return [] unless lines.first&.strip == "---"

    closing = lines[1..].index { |line| line.strip == "---" }
    closing ? lines[1, closing] : []
  end

  def front_matter_fields(path)
    front_matter_lines(path).each_with_object({}) do |line, result|
      match = line.match(/^([a-zA-Z0-9_]+):\s*(.+?)\s*$/)
      result[match[1]] = yaml_scalar(match[2]) if match
    end
  end

  def yaml_scalar(value)
    return nil if value.nil? || value.empty?
    return JSON.parse(value) if value.start_with?("\"")
    return value[1...-1].gsub("''", "'") if value.start_with?("'") && value.end_with?("'")

    value
  rescue JSON::ParserError
    value
  end

  def bundle_hash(bundle)
    digest = Digest::SHA256.new
    bundle.glob("**/*", File::FNM_DOTMATCH).select { |path| path.file? && !path.symlink? }.sort_by(&:to_s).each do |path|
      digest << path.relative_path_from(bundle).to_s << "\0"
      File.open(path, "rb") { |file| digest << file.read(64 * 1024) until file.eof? }
      digest << "\0"
    end
    digest.hexdigest
  end

  def latest_mtime(bundle)
    entries = bundle.glob("**/*", File::FNM_DOTMATCH).select { |path| path.file? && !path.symlink? }
    entries.empty? ? bundle.mtime : entries.map(&:mtime).max
  end

  def slugify(title)
    slug = title
      .unicode_normalize(:nfc)
      .tr("/\\", "-")
      .gsub(/[\x00-\x1f]/, "")
      .gsub(/\s+/, "-")
      .gsub(/-+/, "-")
      .sub(/\A[.\-]+/, "")
      .sub(/[.\-]+\z/, "")
    raise ArgumentError, "title cannot produce a slug" if slug.empty?

    slug
  end

  def safe_asset_name(filename)
    filename.unicode_normalize(:nfc).tr("/\\", "-").gsub(/\s+/, "-").gsub(/-+/, "-")
  end

  def normalize(value)
    value.to_s.unicode_normalize(:nfc).strip
  end

  def inside?(path, parent)
    path == parent || path.to_s.start_with?(parent.to_s + File::SEPARATOR)
  end

  def symlinked_path?(path, root)
    relative = path.relative_path_from(root)
    current = root
    relative.each_filename do |component|
      current = current.join(component)
      return true if current.symlink?
    end
    false
  rescue ArgumentError
    true
  end

  def relative_repo_path(path)
    inside?(path.cleanpath, @repo) ? path.cleanpath.relative_path_from(@repo).to_s : path.cleanpath.to_s
  end

  def git_state
    branch = git_output("branch", "--show-current").strip
    head = git_output("rev-parse", "HEAD").strip
    status = git_output("status", "--porcelain", "--untracked-files=all").lines.map(&:chomp)
    origin_main, _stderr, origin_status = Open3.capture3("git", "rev-parse", "--verify", "refs/remotes/origin/main", chdir: @repo.to_s)
    remote = origin_status.success? ? origin_main.strip : nil
    ahead = behind = nil
    if remote
      counts = git_output("rev-list", "--left-right", "--count", "HEAD...refs/remotes/origin/main").split.map(&:to_i)
      ahead, behind = counts
    end
    {
      "branch" => branch,
      "head" => head,
      "cached_origin_main" => remote,
      "head_matches_cached_origin_main" => remote == head,
      "ahead" => ahead,
      "behind" => behind,
      "clean" => status.empty?,
      "status" => status
    }
  end

  def git_output(*arguments)
    stdout, stderr, status = Open3.capture3("git", *arguments, chdir: @repo.to_s)
    raise ArgumentError, "git #{arguments.join(' ')} failed: #{stderr.strip}" unless status.success?

    stdout
  end

  def receipt_path
    @repo.join(".myblog", "published.json")
  end

  def load_receipts
    return [] unless receipt_path.file?

    data = JSON.parse(receipt_path.read(encoding: "UTF-8"))
    raise ArgumentError, "receipt file must contain a JSON array" unless data.is_a?(Array)

    data
  rescue JSON::ParserError => e
    raise ArgumentError, "invalid receipt file: #{e.message}"
  end

  def write_receipts(data)
    FileUtils.mkdir_p(receipt_path.dirname)
    temporary = receipt_path.sub_ext(".tmp")
    temporary.write(JSON.pretty_generate(data) + "\n", encoding: "UTF-8")
    File.rename(temporary, receipt_path)
  ensure
    FileUtils.rm_f(temporary) if defined?(temporary)
  end
end

command = ARGV.shift
options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: inspect_inbox.rb <inspect|record> [options]"
  opts.on("--repo PATH") { |value| options[:repo] = value }
  opts.on("--inbox PATH") { |value| options[:inbox] = value }
  opts.on("--title TITLE") { |value| options[:title] = value }
  opts.on("--modified-on YYYY-MM-DD") { |value| options[:modified_on] = Date.iso8601(value) }
  opts.on("--bundle PATH") { |value| options[:bundle] = value }
  opts.on("--post PATH") { |value| options[:post] = value }
  opts.on("--commit SHA") { |value| options[:commit] = value }
  opts.on("--url URL") { |value| options[:url] = value }
end

begin
  parser.parse!
  raise ArgumentError, parser.to_s unless ARGV.empty? && %w[inspect record].include?(command)

  default_repo = Pathname(__dir__).join("../../../..").expand_path
  inspector = InboxInspector.new(repo: options.fetch(:repo, default_repo), inbox: options[:inbox])
  result = if command == "inspect"
             inspector.inspect(title: options[:title], modified_on: options[:modified_on])
           else
             required = %i[bundle post commit url]
             missing = required.reject { |key| options[key] && !options[key].empty? }
             raise ArgumentError, "missing options: #{missing.join(', ')}" unless missing.empty?
             inspector.record(bundle: options[:bundle], post: options[:post], commit: options[:commit], url: options[:url])
           end
  puts JSON.pretty_generate(result)
rescue ArgumentError, Date::Error, Errno::ENOENT, Errno::EACCES => e
  warn "error: #{e.message}"
  exit 1
end
