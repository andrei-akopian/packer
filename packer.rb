#!/usr/bin/env ruby
# frozen_string_literal: true

# packer.rb - single-file compress + encrypt utility in Ruby (stdlib only).
# Gist:    https://gist.github.com/<author>/<gist-id>
# Author:  andrei
# Date:    2026-08-03
# v1.0.0
# Scans which CLI tools are installed, validates the backends the user asked
# for, then compresses and (optionally) encrypts a target folder, printing a
# Before / After overview. No external gems required.
# Usage:
#   ./packer.rb -c zip -e age -i tree ~/photos
#   ./packer.rb --compress 7z --encrypt gpg --info du mydata
#   ./packer.rb --help

require "shellwords"

VERSION = "1.0.0"

# Backend catalog. Each backend lists the exact binaries it needs; they are
# looked up on PATH in order and the first hit is used as the primary binary.
BACKENDS = {
  compress: {
    "zip"   => { tools: %w[zip],       ext: ".zip",     desc: "zip" },
    "bz2"   => { tools: %w[tar bzip2], ext: ".tar.bz2", desc: "tar + bzip2" },
    "7z"    => { tools: %w[7z 7za 7zr], ext: ".7z",     desc: "7-Zip" },
    "ouch"  => { tools: %w[ouch zstd], ext: ".tar.zst", desc: "ouch + zstd" },
    "xz"    => { tools: %w[tar xz],    ext: ".tar.xz",  desc: "tar + xz" },
    "zstd"  => { tools: %w[tar zstd],  ext: ".tar.zst", desc: "tar + zstd" },
    "atool" => { tools: %w[apack],     ext: ".tar.gz",  desc: "atool/apack" }
  },
  encrypt: {
    "kryptor"   => { tools: %w[kryptor],   ext: ".kryptor", desc: "kryptor" },
    "age"       => { tools: %w[age],       ext: ".age",     desc: "age -p" },
    "gpg"       => { tools: %w[gpg],       ext: ".gpg",     desc: "gpg --symmetric" },
    "picocrypt" => { tools: %w[picocrypt], ext: ".pcv",     desc: "picocrypt" }
  },
  info: {
    "tree" => { tools: %w[tree], desc: "tree -h" },
    "du"   => { tools: %w[du],   desc: "du -h" },
    "gdu"  => { tools: %w[gdu],  desc: "gdu -h" }
  }
}.freeze

ORDER = %i[compress encrypt info].freeze

USAGE = <<~TEXT
  packer v#{VERSION} - compress and encrypt a folder with installed CLI tools.

  Usage: packer [options] <target>

  Options:
    -c, --compress TOOL   Compression backend (default: first available)
    -e, --encrypt TOOL    Encryption backend (default: none)
    -i, --info TOOL       Info backend for the file listing (tree, du, gdu)
    -o, --output FILE     Archive path (default: ./<target>_<timestamp><ext>)
    -h, --help            Show this help

  The target must exist. Every requested backend is validated against the
  tools detected on this system and a mismatch is reported up front. When
  encrypting, the plain archive is kept alongside the encrypted file.
TEXT

def banner
  "packer v#{VERSION} - Before/After compress + encrypt"
end

def hr(char = "=", n = 64)
  char * n
end

# ---------------------------------------------------------------------------
# Argument parsing (forgiving: --key=value and --key value both work)
# ---------------------------------------------------------------------------
def parse_args(argv)
  opts = { compress: nil, encrypt: nil, info: nil, output: nil, help: false, target: nil }
  key_map = { "c" => :compress, "e" => :encrypt, "i" => :info, "o" => :output }

  i = 0
  while i < argv.size
    arg = argv[i]
    case arg
    when "-h", "--help"
      opts[:help] = true
    when /^--(compress|encrypt|info|output)(?:=(.*))?$/
      key = Regexp.last_match(1).to_sym
      val = Regexp.last_match(2)
      val = argv[i += 1] if val.nil? || val.empty?
      unless val
        warn "Error: #{arg} requires a value"
        return usage_error
      end
      opts[key] = val
    when /^-[ceio]$/
      key = key_map[arg[1]]
      val = argv[i += 1]
      unless val
        warn "Error: #{arg} requires a value"
        return usage_error
      end
      opts[key] = val
    when /^-/
      warn "Error: unknown option '#{arg}'"
      return usage_error
    else
      if opts[:target]
        warn "Error: only one target folder is allowed"
        return usage_error
      end
      opts[:target] = arg
    end
    i += 1
  end
  opts
end

def usage_error
  { error: true }
end

# ---------------------------------------------------------------------------
# Tool detection
# ---------------------------------------------------------------------------
def find_tool(cmd)
  ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
    path = File.join(dir, cmd)
    return path if File.file?(path) && File.executable?(path)
  end
  nil
end

def scan_availability
  detected = {}
  BACKENDS.each do |cat, list|
    detected[cat] = {}
    list.each do |name, spec|
      detected[cat][name] = spec[:tools].map { |t| find_tool(t) }
    end
  end
  detected
end

def tool_ok?(bins)
  bins && bins.none?(&:nil?)
end

def first_available(cat_bins)
  cat_bins.each { |name, bins| return name if tool_ok?(bins) }
  nil
end

# ---------------------------------------------------------------------------
# Validation: requested backend must be known AND fully available.
# ---------------------------------------------------------------------------
def validate!(opts, detected)
  ORDER.each do |cat|
    name = opts[cat]
    next if name.nil?

    unless BACKENDS[cat].key?(name)
      warn "Error: unknown #{cat} backend '#{name}'."
      warn "       Known #{cat} backends: #{BACKENDS[cat].keys.join(', ')}"
      return 1
    end

    bins = detected[cat][name]
    unless tool_ok?(bins)
      want = BACKENDS[cat][name][:tools].join(', ')
      got  = bins.compact.join(', ')
      have = BACKENDS[cat].select { |n, _| tool_ok?(detected[cat][n]) }.keys.join(', ')
      warn "Error: #{cat} backend '#{name}' needs [#{want}] but only found: [#{got}]"
      warn "       Available #{cat} backends: #{have.empty? ? 'none' : have}"
      return 1
    end
  end
  nil
end

# ---------------------------------------------------------------------------
# Size / listing helpers
# ---------------------------------------------------------------------------
def human_size(bytes)
  bytes = bytes.to_f
  return "0 B" if bytes.zero?

  units = %w[B KB MB GB TB PB]
  i = 0
  while bytes >= 1024 && i < units.size - 1
    bytes /= 1024
    i += 1
  end
  format("%6.1f %s", bytes, units[i])
end

def collect_files(target)
  if File.directory?(target)
    Dir.glob(File.join(target, "**", "*"), File::FNM_DOTMATCH).select { |p| File.file?(p) }
  elsif File.file?(target)
    [target]
  else
    []
  end
end

def print_file_list(files, cap = 100)
  return if files.empty?

  files.each_with_index do |f, idx|
    if idx >= cap
      puts "  ... and #{files.size - cap} more file(s)"
      break
    end
    puts "  %8s  %s" % [human_size(File.size(f)), f]
  end
end

# ---------------------------------------------------------------------------
# Command builders (paths are shell-escaped; bins are resolved absolute paths)
# ---------------------------------------------------------------------------
def compress_command(name, out, target, bins)
  o = Shellwords.escape(out)
  t = Shellwords.escape(target)
  case name
  when "zip"   then "#{bins[0]} -r -q #{o} #{t}"
  when "bz2"   then "#{bins[0]} -cjf #{o} #{t}"
  when "7z"    then "#{bins[0]} a -bso0 -bsp0 #{o} #{t}"
  when "ouch"  then "#{bins[0]} compress #{t} #{o}"
  when "xz"    then "#{bins[0]} -cJf #{o} #{t}"
  when "zstd"  then "#{bins[0]} -cf - #{t} | #{bins[1]} -q -o #{o}"
  when "atool" then "#{bins[0]} #{o} #{t}"
  end
end

def encrypt_command(name, input, output, bins)
  i = Shellwords.escape(input)
  o = Shellwords.escape(output)
  case name
  when "kryptor"   then "#{bins[0]} encrypt #{i} -o #{o}"
  when "age"       then "#{bins[0]} -p -o #{o} #{i}"
  when "gpg"       then "#{bins[0]} --symmetric --cipher-algo AES256 -o #{o} #{i}"
  when "picocrypt" then "#{bins[0]} -e #{i} #{o}"
  end
end

def info_command(name, target, bin)
  case name
  when "tree" then Shellwords.join([bin, "-h", target])
  when "du"   then Shellwords.join([bin, "-h", target])
  when "gdu"  then Shellwords.join([bin, "-nh", target])
  end
end

# ---------------------------------------------------------------------------
# Runner steps
# ---------------------------------------------------------------------------
def run_compress(name, target, out, bins)
  puts "\n== Compressing with '#{name}' =="
  cmd = compress_command(name, out, target, bins)
  ok = system(cmd)
  unless ok
    warn "Error: compression command failed: #{cmd}"
    File.delete(out) if File.exist?(out)
    return false
  end
  true
end

def run_encrypt(name, archive, out, bins)
  puts "\n== Encrypting with '#{name}' =="
  puts "    (you will be prompted for a passphrase)"
  cmd = encrypt_command(name, archive, out, bins)
  ok = system(cmd)
  unless ok
    warn "Error: encryption command failed: #{cmd}"
    File.delete(out) if File.exist?(out)
    return false
  end
  true
end

def run_info(name, target, bin)
  cmd = info_command(name, target, bin)
  puts "  Listing via #{name}:"
  system(cmd)
end

def print_before(target, files, total, info_name, detected)
  puts hr
  puts "BEFORE"
  puts "  Target:      #{target}"
  puts "  File count:  #{files.size}"
  puts "  Total size:  #{human_size(total)}"
  if info_name && detected[:info][info_name]
    run_info(info_name, target, detected[:info][info_name][0])
  else
    print_file_list(files)
  end
  puts hr
end

def print_after(archive, enc_out, total)
  puts hr
  puts "AFTER"
  if archive && File.exist?(archive)
    puts "  Archive:     #{archive}"
    puts "  Archive:     #{human_size(File.size(archive))}  (#{pct(File.size(archive), total)})"
  end
  if enc_out && File.exist?(enc_out)
    puts "  Encrypted:   #{enc_out}"
    puts "  Encrypted:   #{human_size(File.size(enc_out))}  (#{pct(File.size(enc_out), total)})"
  end
  puts hr
end

def pct(size, total)
  return "0.0% of original" if total.to_f.zero?

  format("%.1f%% of original", 100.0 * size / total)
end

def default_archive_name(target, ext)
  ts = Time.now.strftime("%Y%m%d-%H%M%S")
  File.join(Dir.pwd, "#{File.basename(target)}_#{ts}#{ext}")
end

def ensure_outdir(path)
  dir = File.dirname(path)
  return true if File.directory?(dir)

  warn "Error: output directory does not exist: #{dir}"
  false
end

def print_detected(detected)
  puts "Detected backends:"
  BACKENDS.each do |cat, list|
    parts = list.map do |name, _spec|
      tool_ok?(detected[cat][name]) ? name : "#{name}(missing)"
    end
    puts "  %-9s %s" % [cat, parts.join("  ")]
  end
  puts
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main(argv)
  opts = parse_args(argv)
  if opts[:error]
    puts USAGE
    return 2
  end
  if opts[:help]
    puts USAGE
    return 0
  end
  unless opts[:target]
    warn "Error: no target folder given"
    puts USAGE
    return 2
  end

  target = File.expand_path(opts[:target])
  unless File.exist?(target)
    warn "Error: target does not exist: #{target}"
    return 1
  end

  puts banner
  detected = scan_availability
  print_detected(detected)

  opts[:compress] = first_available(detected[:compress]) if opts[:compress].nil? && !opts[:encrypt].nil?
  opts[:info]     = first_available(detected[:info])     if opts[:info].nil?

  code = validate!(opts, detected)
  return code if code

  files = collect_files(target)
  total = files.sum { |p| File.size(p) }

  print_before(target, files, total, opts[:info], detected)

  archive = nil
  enc_out = nil

  if opts[:compress]
    ext = BACKENDS[:compress][opts[:compress]][:ext]
    archive = opts[:output] ? File.expand_path(opts[:output]) : default_archive_name(target, ext)
    return 1 unless ensure_outdir(archive)
    return 1 unless run_compress(opts[:compress], target, archive, detected[:compress][opts[:compress]])
  end

  if opts[:encrypt]
    unless archive
      warn "Error: encryption requires an archive; also pass a compress backend."
      return 1
    end
    enc_out = archive + BACKENDS[:encrypt][opts[:encrypt]][:ext]
    return 1 unless run_encrypt(opts[:encrypt], archive, enc_out, detected[:encrypt][opts[:encrypt]])
  end

  print_after(archive, enc_out, total)
  puts "Done."
  0
end

exit main(ARGV) if $PROGRAM_NAME == __FILE__
