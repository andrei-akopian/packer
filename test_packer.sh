#!/usr/bin/env bash
# test_packer.sh - automated tests for packer.rb
#
# Tests detection, help, error handling, compression, decompression, compression
# levels, and encryption round-trips against the tools that are installed on
# this machine.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKER="$SCRIPT_DIR/packer.rb"

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
# Backend catalog is derived from packer.rb so tests stay in sync.
# ---------------------------------------------------------------------------
installed_formats() { # $1 = category
  ruby -e '
    load ARGV[0]
    puts installed_backends(ARGV[1].to_sym).join(" ")
  ' "$PACKER" "$1"
}

all_formats() { # $1 = category
  ruby -e '
    load ARGV[0]
    catalog(ARGV[1].to_sym).each { |n, _| puts n }
  ' "$PACKER" "$1"
}

ext_of() { # $1 = category, $2 = format name
  ruby -e '
    load ARGV[0]
    puts catalog(ARGV[1].to_sym)[ARGV[2]].ext
  ' "$PACKER" "$1" "$2"
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
trap 'rm -rf "$TMP"' EXIT
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
MOCK_BIN="$SCRIPT_DIR/test/mocks"
TS_ARCHIVE="$TMP/timestamp.zip"
TS_RESTORED="$TMP/timestamp_restored"
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
