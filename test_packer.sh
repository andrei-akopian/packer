#!/usr/bin/env bash
# test_packer.sh - automated tests for packer.rb
# Runs detection, error-handling, compression and (encrypted) round-trip tests
# against whichever backends are actually installed on this machine.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKER="$SCRIPT_DIR/packer.rb"

# >= 8 chars on purpose: keeps gpg's pinentry from asking to accept a
# "weak" passphrase, which would otherwise need an extra keystroke.
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
# Backend catalog is derived FROM packer.rb itself (no copy to keep in sync).
# ---------------------------------------------------------------------------
installed_backends() { # $1 = category (compress|encrypt)
  ruby -e '
    load ARGV[0]
    cat = ARGV[1].to_sym
    puts BACKENDS[cat].select { |n, s| s[:tools].all? { |t| find_tool(t) } }.keys.join(" ")
  ' "$PACKER" "$1"
}

all_backends() { # $1 = category
  ruby -e 'load ARGV[0]; puts BACKENDS[ARGV[1].to_sym].keys.join(" ")' "$PACKER" "$1"
}

ext_of() { # $1 = category, $2 = backend name
  ruby -e 'load ARGV[0]; puts BACKENDS[ARGV[1].to_sym][ARGV[2]][:ext]' "$PACKER" "$1" "$2"
}

# ---------------------------------------------------------------------------
# Drive interactive passphrase prompts through a pty. Passphrase prompts are
# read from the tty (not stdin), so we allocate a pty via `script`, wait for
# the prompt to appear, then feed the passphrase(s) and keep the tty open.
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

# Fresh, compressible fixture.
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

if ruby "$PACKER" --help | grep -q "Usage: packer"; then
  ok "--help shows usage"
else
  fail "--help shows usage"
fi

if ruby "$PACKER" --list | grep -q "Detected backends"; then
  ok "--list lists backends"
else
  fail "--list lists backends"
fi

if ! out="$(ruby "$PACKER" -c bogus "$DATA" 2>&1)" && echo "$out" | grep -q "unknown compress backend"; then
  ok "unknown backend is rejected"
else
  fail "unknown backend is rejected"
fi

if ! ruby "$PACKER" /no/such/path >/dev/null 2>&1; then
  ok "nonexistent target is rejected"
else
  fail "nonexistent target is rejected"
fi

# Request a compress backend that is NOT installed -> mismatch error.
all_c="$(all_backends compress)"
inst_c="$(installed_backends compress)"
missing="$(comm -23 <(echo "$all_c" | tr ' ' '\n' | sort) <(echo "$inst_c" | tr ' ' '\n' | sort) | head -1)"
if [ -n "$missing" ]; then
  if ! out="$(ruby "$PACKER" -c "$missing" "$DATA" 2>&1)" && echo "$out" | grep -q "needs"; then
    ok "missing backend '$missing' is a mismatch error"
  else
    fail "missing backend '$missing' is a mismatch error"
  fi
else
  skip "missing-backend mismatch test (all compress backends installed)"
fi

# Info-only run (du is the most common).
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
for b in $(installed_backends compress); do
  out="$TMP/c_$b$(ext_of compress "$b")"
  if ruby "$PACKER" -c "$b" -o "$out" "$DATA" >/dev/null 2>&1 \
     && [ -s "$out" ]; then
    ok "compress '$b' produces a non-empty archive"
    case "$b" in
      zip)  [ "$(command -v unzip)" ] && unzip -t "$out" >/dev/null 2>&1 && ok "  integrity (unzip -t)"    || fail "  integrity (unzip -t)";;
      bz2)  tar -tjf "$out" >/dev/null 2>&1 && ok "  integrity (tar -tjf)"    || fail "  integrity (tar -tjf)";;
      xz)   tar -tJf "$out" >/dev/null 2>&1 && ok "  integrity (tar -tJf)"    || fail "  integrity (tar -tJf)";;
      zstd) zstd -dc "$out" 2>/dev/null | tar -t >/dev/null 2>&1 && ok "  integrity (zstd|tar)" || fail "  integrity (zstd|tar)";;
      ouch) have 7z && 7z t "$out" >/dev/null 2>&1 && ok "  integrity (7z t)"    || skip "  integrity (7z not used)";;
      *)    skip "  no integrity check for '$b'";;
    esac
  else
    fail "compress '$b' produces a non-empty archive"
  fi
done

# ===========================================================================
heading "Encryption backends (round-trip)"
# ---------------------------------------------------------------------------
# gpg's default pinentry (curses) can't be automated headless; give gpg a
# simple tty pinentry via a throwaway GNUPGHOME. Skip gpg if it is missing.
if command -v pinentry-tty >/dev/null 2>&1; then
  export GNUPGHOME="$TMP/gnupg"
  mkdir -p "$GNUPGHOME"
  chmod 700 "$GNUPGHOME"
  printf 'pinentry-program %s\n' "$(command -v pinentry-tty)" > "$GNUPGHOME/gpg-agent.conf"
  gpgconf --kill gpg-agent >/dev/null 2>&1
else
  skip "gpg skipped (pinentry-tty not installed for headless passphrase)"
fi

enc_list="$(installed_backends encrypt)"
if ! command -v pinentry-tty >/dev/null 2>&1; then
  enc_list="$(printf '%s\n' "$enc_list" | tr ' ' '\n' | grep -v '^gpg$' | tr '\n' ' ')"
fi

for e in $enc_list; do
  out="$TMP/e_$e"
  ext="$(ext_of encrypt "$e")"
  enc="$out$ext"

  if feed_pty "$PASS" ruby "$PACKER" -c xz -e "$e" -o "$out" "$DATA" \
     && [ -s "$enc" ]; then
    ok "encrypt '$e' produces a non-empty $ext file"
  else
    fail "encrypt '$e' produces a non-empty $ext file"
    continue
  fi

  case "$e" in
    openssl)
      if openssl enc -d -aes-256-cbc -pbkdf2 -in "$enc" -out "$TMP/dec_$e" -pass "pass:$PASS" >/dev/null 2>&1 \
         && cmp -s "$TMP/dec_$e" "$out"; then
        ok "  round-trip ($e) matches original archive"
      else
        fail "  round-trip ($e) matches original archive"
      fi
      ;;
    gpg)
      if printf '%s\n' "$PASS" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
         --decrypt -o "$TMP/dec_$e" "$enc" >/dev/null 2>&1 \
         && cmp -s "$TMP/dec_$e" "$out"; then
        ok "  round-trip ($e) matches original archive"
      else
        fail "  round-trip ($e) matches original archive"
      fi
      ;;
    age)
      mkdir -p "$TMP/rt_$e"
      if feed_pty_once "$PASS" age --decrypt -o "$TMP/rt_$e/out" "$enc" \
         && cmp -s "$TMP/rt_$e/out" "$out"; then
        ok "  round-trip ($e) matches original archive"
      else
        fail "  round-trip ($e) matches original archive"
      fi
      ;;
    picocrypt)
      # picocrypt decrypt writes next to the .pcv and refuses to overwrite.
      mkdir -p "$TMP/rt_$e" && cp "$enc" "$TMP/rt_$e/pk.pcv"
      if ( cd "$TMP/rt_$e" && feed_pty_once "$PASS" picocrypt pk.pcv ) \
         && cmp -s "$TMP/rt_$e/pk" "$out"; then
        ok "  round-trip ($e) matches original archive"
      else
        fail "  round-trip ($e) matches original archive"
      fi
      ;;
    *)
      skip "  round-trip ($e) not implemented (unverified CLI)"
      ;;
  esac
done

# ===========================================================================
printf '\n== Summary ==\n'
printf '  \033[32m%s passed\033[0m, \033[31m%s failed\033[0m, \033[33m%s skipped\033[0m\n' \
  "$PASSED" "$FAILED" "$SKIPPED"

[ "$FAILED" -eq 0 ]
