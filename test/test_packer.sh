#!/usr/bin/env bash
# test_packer.sh - integration tests for the packer gem
#
# Tests detection, help, error handling, compression, decompression, compression
# levels, and encryption round-trips against the tools that are installed on
# this machine.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKER="$PROJECT_DIR/exe/packer"
LIBRARY="$PROJECT_DIR/lib/packer.rb"
MOCK_BIN="$SCRIPT_DIR/mocks/packer-test-$$"

# >= 8 characters: keeps gpg from complaining about a weak passphrase.
PASS="PackTest#2026!"

PASSED=0
FAILED=0
SKIPPED=0

ok()   { PASSED=$((PASSED + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  \033[33mSKIP\033[0m %s\n' "$1"; }

heading() { printf '\n== %s ==\n' "$1"; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Backend catalog is derived from the library so tests stay in sync.
# ---------------------------------------------------------------------------
installed_formats() { # $1 = category
  ruby -e '
    load ARGV[0]
    puts Packer.installed_backends(ARGV[1].to_sym).join(" ")
  ' "$LIBRARY" "$1"
}

all_formats() { # $1 = category
  ruby -e '
    load ARGV[0]
    Packer.catalog(ARGV[1].to_sym).each { |n, _| puts n }
  ' "$LIBRARY" "$1"
}

ext_of() { # $1 = category, $2 = format name
  ruby -e '
    load ARGV[0]
    puts Packer.catalog(ARGV[1].to_sym)[ARGV[2]].ext
  ' "$LIBRARY" "$1" "$2"
}

# ---------------------------------------------------------------------------
# Drive interactive passphrase prompts through a pty. Passphrase prompts are
# read from the tty, so we allocate a pty with `script`, wait for the prompt,
# then feed the passphrase(s) and keep the tty open.
# ---------------------------------------------------------------------------
feed_pty() { # $1 = passphrase, rest = command
  local pw="$1"; shift
  local cmd
  printf -v cmd '%q ' "$@"
  ( sleep 1; printf '%s\n%s\n' "$pw" "$pw"; sleep 5 ) \
    | timeout 60 script -qec "$cmd" /dev/null >/dev/null 2>&1
  return ${PIPESTATUS[1]}
}

feed_pty_once() { # single passphrase prompt (for decryption)
  local pw="$1"; shift
  local cmd
  printf -v cmd '%q ' "$@"
  ( sleep 1; printf '%s\n' "$pw"; sleep 5 ) \
    | timeout 60 script -qec "$cmd" /dev/null >/dev/null 2>&1
  return ${PIPESTATUS[1]}
}

# ---------------------------------------------------------------------------
# Fresh, compressible fixture.
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" "$MOCK_BIN"; rmdir "$(dirname "$MOCK_BIN")" 2>/dev/null || true' EXIT
DATA="$TMP/data"
mkdir -p "$DATA/docs"
perl -e 'print "The quick brown fox jumps over the lazy dog.\n" x 20000' > "$DATA/docs/notes.txt"
head -c 200000 /dev/urandom > "$DATA/docs/random.bin"
printf 'hello\n' > "$DATA/docs/readme.md"

# ===========================================================================
heading "Detection, help, and error handling"
# ---------------------------------------------------------------------------

if ruby "$PACKER" --help | grep -q "USAGE"; then
  ok "--help shows usage"
else
  fail "--help shows usage"
fi

if ruby "$PACKER" --list | grep -q "Compression formats"; then
  ok "--list lists formats"
else
  fail "--list lists formats"
fi

if ! out="$(ruby "$PACKER" -c bogus "$DATA" 2>&1)" && echo "$out" | grep -q "unknown compression format"; then
  ok "unknown format is rejected"
else
  fail "unknown format is rejected"
fi

if ! ruby "$PACKER" /no/such/path >/dev/null 2>&1; then
  ok "nonexistent target is rejected"
else
  fail "nonexistent target is rejected"
fi

if ! out="$(ruby "$PACKER" -c zip -o "$DATA/inside.zip" "$DATA" 2>&1)" \
   && printf '%s' "$out" | grep -q "inside the directory being archived" \
   && [ ! -e "$DATA/inside.zip" ]; then
  ok "archive output inside its source directory is rejected"
else
  fail "archive output inside its source directory is rejected"
fi

EXISTING_ARCHIVE="$TMP/existing.zip"
printf 'keep this file unchanged\n' > "$EXISTING_ARCHIVE"
if ! ruby "$PACKER" -c zip -o "$EXISTING_ARCHIVE" "$DATA" >/dev/null 2>&1 \
   && [ "$(<"$EXISTING_ARCHIVE")" = "keep this file unchanged" ]; then
  ok "existing output files are never overwritten"
else
  fail "existing output files are never overwritten"
fi

if ! ruby "$PACKER" -c zip -e unknown -o "$TMP/invalid-encryption" "$DATA" >/dev/null 2>&1 \
   && [ ! -e "$TMP/invalid-encryption.zip" ]; then
  ok "invalid encryption is rejected before creating an archive"
else
  fail "invalid encryption is rejected before creating an archive"
fi

DASH_TARGET="$TMP/-leading-dash.txt"
printf 'dash-leading source\n' > "$DASH_TARGET"
if ruby "$PACKER" -c zip -o "$TMP/dash-source.zip" "$DASH_TARGET" >/dev/null 2>&1 \
   && unzip -t "$TMP/dash-source.zip" >/dev/null 2>&1; then
  ok "source names beginning with a dash are passed as file names"
else
  fail "source names beginning with a dash are passed as file names"
fi

# Request a compression format that is NOT installed -> mismatch error.
all_c="$(all_formats compress)"
inst_c="$(installed_formats compress)"
missing="$(comm -23 <(echo "$all_c" | tr ' ' '\n' | sort) <(echo "$inst_c" | tr ' ' '\n' | sort) | head -1)"
if [ -n "$missing" ]; then
  if ! out="$(ruby "$PACKER" -c "$missing" "$DATA" 2>&1)" && echo "$out" | grep -q "no installed provider"; then
    ok "missing format '$missing' is rejected with a helpful error"
  else
    fail "missing format '$missing' is rejected with a helpful error"
  fi
else
  skip "missing-format mismatch test (all formats installed)"
fi

if have du; then
  if ruby "$PACKER" -i du "$DATA" 2>/dev/null | grep -q "Total size"; then
    ok "info backend (du) shows total size"
  else
    fail "info backend (du) shows total size"
  fi
else
  skip "info backend test (du not installed)"
fi

# ===========================================================================
heading "Compression backends"
# ---------------------------------------------------------------------------
for fmt in $(installed_formats compress); do
  ext="$(ext_of compress "$fmt")"
  out="$TMP/c_${fmt}${ext}"
  if ruby "$PACKER" -c "$fmt" -o "$out" "$DATA" >/dev/null 2>&1 \
     && [ -s "$out" ]; then
    ok "compress '$fmt' produces a non-empty archive"

    case "$fmt" in
      zip)     have unzip && unzip -t "$out" >/dev/null 2>&1 && ok "  integrity (unzip -t)" || fail "  integrity (unzip -t)";;
      tar.gz)  tar -tzf "$out" >/dev/null 2>&1 && ok "  integrity (tar -tzf)" || fail "  integrity (tar -tzf)";;
      tar.bz2) tar -tjf "$out" >/dev/null 2>&1 && ok "  integrity (tar -tjf)" || fail "  integrity (tar -tjf)";;
      tar.xz)  tar -tJf "$out" >/dev/null 2>&1 && ok "  integrity (tar -tJf)" || fail "  integrity (tar -tJf)";;
      tar.zst) tar -tf "$out" >/dev/null 2>&1 && ok "  integrity (tar -t zst)" || fail "  integrity (tar -t zst)";;
      tar)     tar -tf "$out" >/dev/null 2>&1 && ok "  integrity (tar -tf)" || fail "  integrity (tar -tf)";;
      7z)      (have 7z || have 7za) && (7z t "$out" >/dev/null 2>&1 || 7za t "$out" >/dev/null 2>&1) && ok "  integrity (7z t)" || skip "  integrity (7z not installed)";;
      *)       skip "  no integrity check for '$fmt'";;
    esac
  else
    fail "compress '$fmt' produces a non-empty archive"
  fi
done

# ===========================================================================
heading "Compression levels"
# ---------------------------------------------------------------------------
for fmt in $(installed_formats compress); do
  ext="$(ext_of compress "$fmt")"
  for level in none min some max; do
    out="$TMP/l_${fmt}_${level}${ext}"
    if ruby "$PACKER" -c "$fmt" -l "$level" -o "$out" "$DATA" >/dev/null 2>&1 \
       && [ -s "$out" ]; then
      ok "level '$level' for '$fmt' produces a non-empty archive"
    else
      fail "level '$level' for '$fmt' produces a non-empty archive"
    fi
  done
done

# ===========================================================================
heading "Decompression (packer --decompress)"
# ---------------------------------------------------------------------------
for fmt in $(installed_formats compress); do
  ext="$(ext_of compress "$fmt")"
  out="$TMP/d_${fmt}${ext}"
  dir="$TMP/d_${fmt}_out"
  if ruby "$PACKER" -c "$fmt" -o "$out" "$DATA" >/dev/null 2>&1 \
     && ruby "$PACKER" --decompress "$out" -o "$dir" >/dev/null 2>&1 \
     && diff -r "$DATA" "$dir/data" >/dev/null 2>&1; then
    ok "round-trip decompress '$fmt' matches original"
  else
    fail "round-trip decompress '$fmt' matches original"
  fi
done

# ==========================================================================
heading "Timestamping (offline mocked authorities)"
# --------------------------------------------------------------------------
TS_ARCHIVE="$TMP/timestamp.zip"
TS_RESTORED="$TMP/timestamp_restored"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/ots" <<'MOCK_OTS'
#!/usr/bin/env ruby
if ARGV[0] == "stamp"
  File.binwrite("#{ARGV[1]}.ots", "mock OpenTimestamps proof")
elsif ARGV[0] == "verify"
  puts "Calendar: Pending confirmation in Bitcoin blockchain"
  exit(File.file?(ARGV[1]) ? 0 : 1)
else
  exit 2
end
MOCK_OTS
cat > "$MOCK_BIN/openssl" <<'MOCK_OPENSSL'
#!/usr/bin/env ruby
if ARGV[0] == "ts" && ARGV.include?("-query")
  File.binwrite(ARGV[ARGV.index("-out") + 1], "mock timestamp query")
  exit 0
elsif ARGV[0] == "ts" && ARGV.include?("-verify")
  data = ARGV[ARGV.index("-data") + 1]
  response = ARGV[ARGV.index("-in") + 1]
  exit(File.file?(data) && File.file?(response) ? 0 : 1)
end
exit 2
MOCK_OPENSSL
cat > "$MOCK_BIN/curl" <<'MOCK_CURL'
#!/usr/bin/env ruby
output = ARGV[ARGV.index("--output") + 1]
File.binwrite(output, "mock RFC 3161 response")
exit 0
MOCK_CURL
chmod +x "$MOCK_BIN/ots" "$MOCK_BIN/openssl" "$MOCK_BIN/curl"
if PATH="$MOCK_BIN:$PATH" ruby "$PACKER" -c zip -o "$TS_ARCHIVE" \
   --timestamp both --tsa-url sectigo "$DATA" >/dev/null 2>&1 \
   && [ -s "$TS_ARCHIVE.ots" ] && [ -s "$TS_ARCHIVE.tsr" ]; then
  ok "both timestamp modes create detached proof sidecars"
else
  fail "both timestamp modes create detached proof sidecars"
fi

if PATH="$MOCK_BIN:$PATH" ruby "$PACKER" --verify-timestamp "$TS_ARCHIVE" >/dev/null 2>&1; then
  ok "adjacent OpenTimestamps and RFC 3161 proofs can be verified"
else
  fail "adjacent OpenTimestamps and RFC 3161 proofs can be verified"
fi

if PATH="$MOCK_BIN:$PATH" ruby "$PACKER" -d "$TS_ARCHIVE" -o "$TS_RESTORED" \
   --delete-after-unzip >/dev/null 2>&1 \
   && diff -r "$DATA" "$TS_RESTORED/data" >/dev/null 2>&1 \
   && [ ! -e "$TS_ARCHIVE" ] && [ ! -e "$TS_ARCHIVE.ots" ] && [ ! -e "$TS_ARCHIVE.tsr" ]; then
  ok "autodelete removes the archive and timestamp proofs after successful extraction"
else
  fail "autodelete removes the archive and timestamp proofs after successful extraction"
fi

# ==========================================================================
heading "Encryption backends (round-trip)"
# ---------------------------------------------------------------------------
# gpg's default pinentry (curses) cannot be automated headless; give it a
# simple tty pinentry via a throwaway GNUPGHOME.
if command -v pinentry-tty >/dev/null 2>&1; then
  export GNUPGHOME="$TMP/gnupg"
  mkdir -p "$GNUPGHOME"
  chmod 700 "$GNUPGHOME"
  printf 'pinentry-program %s\n' "$(command -v pinentry-tty)" > "$GNUPGHOME/gpg-agent.conf"
  gpgconf --kill gpg-agent >/dev/null 2>&1 || true
else
  skip "gpg skipped (pinentry-tty not installed for headless passphrase)"
fi

enc_list="$(installed_formats encrypt)"
if ! command -v pinentry-tty >/dev/null 2>&1; then
  enc_list="$(printf '%s\n' "$enc_list" | tr ' ' '\n' | grep -v '^gpg$' | tr '\n' ' ')"
fi

for e in $enc_list; do
  ext="$(ext_of encrypt "$e")"
  out="$TMP/e_$e"
  enc="${out}.tar.gz${ext}"

  if feed_pty "$PASS" ruby "$PACKER" -c tar.gz -e "$e" -o "$out" "$DATA" \
     && [ -s "$enc" ]; then
    ok "encrypt '$e' produces a non-empty $ext file"
  else
    fail "encrypt '$e' produces a non-empty $ext file"
    continue
  fi

  case "$e" in
    openssl)
      if openssl enc -d -aes-256-cbc -pbkdf2 -in "$enc" -out "$TMP/dec_$e" -pass "pass:$PASS" >/dev/null 2>&1 \
         && tar -xzf "$TMP/dec_$e" -C "$TMP" >/dev/null 2>&1 \
         && diff -r "$DATA" "$TMP/data" >/dev/null 2>&1; then
        ok "  direct round-trip ($e) matches original"
      else
        fail "  direct round-trip ($e) matches original"
      fi
      ;;
    gpg)
      if printf '%s\n' "$PASS" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
         --decrypt -o "$TMP/dec_$e" "$enc" >/dev/null 2>&1 \
         && tar -xzf "$TMP/dec_$e" -C "$TMP" >/dev/null 2>&1 \
         && diff -r "$DATA" "$TMP/data" >/dev/null 2>&1; then
        ok "  direct round-trip ($e) matches original"
      else
        fail "  direct round-trip ($e) matches original"
      fi
      ;;
    age)
      mkdir -p "$TMP/rt_$e"
      if feed_pty_once "$PASS" age --decrypt -o "$TMP/rt_$e/out.tar.gz" "$enc" \
         && tar -xzf "$TMP/rt_$e/out.tar.gz" -C "$TMP/rt_$e" >/dev/null 2>&1 \
         && diff -r "$DATA" "$TMP/rt_$e/data" >/dev/null 2>&1; then
        ok "  direct round-trip ($e) matches original"
      else
        fail "  direct round-trip ($e) matches original"
      fi
      ;;
    kryptor)
      if feed_pty_once "$PASS" kryptor decrypt "$enc" -o "$TMP/dec_$e" >/dev/null 2>&1 \
         && tar -xzf "$TMP/dec_$e" -C "$TMP" >/dev/null 2>&1 \
         && diff -r "$DATA" "$TMP/data" >/dev/null 2>&1; then
        ok "  direct round-trip ($e) matches original"
      else
        fail "  direct round-trip ($e) matches original"
      fi
      ;;
    picocrypt)
      mkdir -p "$TMP/rt_$e" && cp "$enc" "$TMP/rt_$e/pk.tar.gz.pcv"
      if ( cd "$TMP/rt_$e" && feed_pty_once "$PASS" picocrypt pk.tar.gz.pcv ) \
         && tar -xzf "$TMP/rt_$e/pk.tar.gz" -C "$TMP/rt_$e" >/dev/null 2>&1 \
         && diff -r "$DATA" "$TMP/rt_$e/data" >/dev/null 2>&1; then
        ok "  direct round-trip ($e) matches original"
      else
        fail "  direct round-trip ($e) matches original"
      fi
      ;;
    *)
      skip "  direct round-trip ($e) not implemented (unverified CLI)"
      ;;
  esac

  # Also verify packer's own --decompress mode for the encrypted archive.
  mkdir -p "$TMP/pd_$e"
  if feed_pty_once "$PASS" ruby "$PACKER" --decompress "$enc" -o "$TMP/pd_$e" >/dev/null 2>&1 \
     && diff -r "$DATA" "$TMP/pd_$e/data" >/dev/null 2>&1; then
    ok "  packer --decompress ($e) matches original"
  else
    fail "  packer --decompress ($e) matches original"
  fi
done

# ===========================================================================
printf '\n== Summary ==\n'
printf '  \033[32m%s passed\033[0m, \033[31m%s failed\033[0m, \033[33m%s skipped\033[0m\n' \
  "$PASSED" "$FAILED" "$SKIPPED"

[ "$FAILED" -eq 0 ]
