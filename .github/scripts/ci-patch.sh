#!/usr/bin/env bash
#
# Build-time patches for CI builds.
#
# These are applied to the checkout at build time and never committed. That is
# deliberate: it keeps the fork "upstream + one .github/ commit", so
#     git pull --rebase upstream dev
# always replays cleanly — every file the fork adds is new, so nothing can
# collide. Editing tracked source here would turn every sync into a conflict
# fight against whatever upstream changed that week.
#
# Idempotent. Fails loudly if an anchor disappears, rather than silently
# no-op'ing and quietly costing hours of runner time.
#
# ASSUMES A RELEASE BUILD. Do NOT combine with prepare.py's 'skip-release':
# that skips the Release builds this script leaves as the only ones, so
# tg_angle and tg_owt would be configured and never built, and Qt would fall
# back to -debug and link a tg_angle.lib that no longer exists.

set -euo pipefail

ROOT="${1:?usage: ci-patch.sh <repo-root>}"
cd "$ROOT"

PREPARE="Telegram/build/prepare/prepare.py"
INFRA="Telegram/SourceFiles/ayu/ayu_infra.cpp"
SETUP="Telegram/build/setup.iss"

fail() {
	echo "::error::ci-patch: $1"
	exit 1
}

# `sed -i EXPR FILE` is GNU-only. BSD sed (macOS) reads the token after -i as a
# backup suffix, so it swallows EXPR and then treats FILE as the script:
# "invalid command code f", exit 1. Write through a temp file instead — that
# behaves identically everywhere and needs no GNU/BSD branch.
sed_i() { # sed_i <expr> <file>
	local tmp
	# Template is explicit: BSD mktemp requires one. Placing it beside the target
	# also keeps the mv on the same filesystem.
	tmp="$(mktemp "$2.ci-patch.XXXXXX")" || fail "mktemp failed next to $2"
	sed "$1" "$2" > "$tmp" || { rm -f "$tmp"; fail "sed '$1' failed on $2"; }
	mv "$tmp" "$2" || { rm -f "$tmp"; fail "could not write $2"; }
}

for f in "$PREPARE" "$INFRA" "$SETUP"; do
	[ -f "$f" ] || fail "$f not found — wrong root?"
done

# ---------------------------------------------------------------------------
# 1. Build the dependencies Release-only.
#
# The app is only ever built Release, but prepare.py compiles every library
# Debug AND Release ('skip-release' would give Debug-only, which a Release app
# cannot link against: /MT vs /MTd). Dropping the Debug half is worth roughly
# 40% of the cold dependency build — the difference between fitting GitHub's
# hard 6h job cap and never finishing at all.
# ---------------------------------------------------------------------------

if grep -q 'CONFIGURATIONS=-debug-and-release' "$PREPARE"; then
	sed_i 's/CONFIGURATIONS=-debug-and-release/CONFIGURATIONS=-release/g' "$PREPARE"
	echo "patched: Qt configured -release (was -debug-and-release)"
elif grep -q 'CONFIGURATIONS=-release' "$PREPARE"; then
	echo "skipped: Qt already -release"
else
	fail "no CONFIGURATIONS=-debug-and-release anchor in $PREPARE — upstream changed the Qt stage, re-check this patch"
fi

# tg_owt, tg_angle, opus and ada each build Debug and then Release into the same
# tree; only the Release artifacts are ever installed or linked, so the Debug
# pass is pure waste. Each of these lines is followed by its Release counterpart,
# so deleting it leaves a working stage. openssl3 and tde2e are NOT touched:
# their release steps read state the debug step leaves behind.
if grep -q 'cmake --build out --config Debug' "$PREPARE"; then
	COUNT=$(grep -c 'cmake --build out --config Debug' "$PREPARE")
	sed_i '/cmake --build out --config Debug/d' "$PREPARE"
	echo "patched: dropped $COUNT Debug library builds"
else
	echo "skipped: Debug library builds already dropped"
fi

# breakpad builds a `dump_syms` tool that #includes ATL (atlbase.h,
# atlcomcli.h). The runners' Visual Studio has no ATL component, so it dies with
# C1083 and takes the whole dependency build with it.
#
# Nothing we build needs it: dump_syms only dumps symbols for the crash-report
# upload pipeline, and it is referenced solely by Telegram/build/build.bat and
# build.sh — the official deploy scripts, which CI never runs. CMake never looks
# for it, and we build with DESKTOP_APP_DISABLE_CRASH_REPORTS=ON regardless.
# breakpad's actual libraries still build; only the tool is dropped.
#
# Upstream CI never trips over this because it passes skip-release, which skips
# the entire `release:` block these lines live in.
if grep -q 'dump_syms' "$PREPARE"; then
	COUNT=$(grep -c 'dump_syms' "$PREPARE")
	sed_i '/dump_syms/d' "$PREPARE"
	echo "patched: dropped $COUNT dump_syms lines (needs ATL, absent from the runners' VS)"
else
	echo "skipped: dump_syms already dropped"
fi

# ---------------------------------------------------------------------------
# 2. Silence the update.ayugram.one beacon.
#
# DESKTOP_APP_DISABLE_AUTOUPDATE kills the updater itself, but NOT this:
# RCManager fetches https://update.ayugram.one/rc/current/desktop2 at startup
# and every hour thereafter, regardless of the flag. The hardcoded developer and
# channel lists in rc_manager.cpp remain, so badges still render — they just
# stop being refreshed from Radolyn's server.
# ---------------------------------------------------------------------------

# POSIX classes, not \s: BSD grep/sed do not understand GNU's \s shorthand.
if grep -q '^[[:space:]]*initRCManager();' "$INFRA"; then
	sed_i 's|^\([[:space:]]*\)initRCManager();|\1// initRCManager(); // ci-patch: no update.ayugram.one beacon|' "$INFRA"
	echo "patched: RCManager beacon disabled"
elif grep -q 'ci-patch: no update.ayugram.one beacon' "$INFRA"; then
	echo "skipped: RCManager beacon already disabled"
else
	fail "no initRCManager() call site in $INFRA — upstream changed init(), re-check this patch"
fi

# ---------------------------------------------------------------------------
# 3. Make the Inno Setup script compile against what CI actually produces.
#
# setup.iss is written for the official release pipeline, which CI is not:
#   - it installs Telegram.exe, but our CMake sets output_name to AyuGram;
#   - it installs Updater.exe, which DESKTOP_APP_DISABLE_AUTOUPDATE never
#     builds — so ISCC would abort on a missing source file;
#   - SignTool=sha256 names a signing tool that only exists on the release
#     machine's Inno install, and we hold no code-signing certificate.
# ---------------------------------------------------------------------------

if grep -q 'Telegram\.exe' "$SETUP"; then
	sed_i 's/Telegram\.exe/AyuGram.exe/g' "$SETUP"
	echo "patched: setup.iss installs AyuGram.exe"
elif grep -q 'Source:.*AyuGram\.exe' "$SETUP"; then
	# Anchored on the Source: line, not on a bare AyuGram.exe: a pristine
	# setup.iss already carries `#define MyAppExeName "AyuGram.exe"`, which this
	# rule never touches, so the looser test would match every time and the fail
	# below could never fire.
	echo "skipped: setup.iss already names AyuGram.exe"
else
	fail "no Telegram.exe reference in $SETUP — upstream reworked the installer, re-check this patch"
fi

if grep -q 'Source:.*Updater\.exe' "$SETUP"; then
	sed_i '/Source:.*Updater\.exe/d' "$SETUP"
	echo "patched: dropped Updater.exe from the installer (autoupdate is off, so it is never built)"
else
	echo "skipped: Updater.exe already absent from the installer"
fi

if grep -q '^SignTool=' "$SETUP"; then
	sed_i '/^SignTool=/d' "$SETUP"
	echo "patched: dropped SignTool (no code-signing certificate in CI)"
else
	echo "skipped: SignTool already dropped"
fi

# Qt6 builds emit no ANGLE, so this DLL is genuinely absent there and ISCC
# treats a missing [Files] source as a fatal error. The Package step in the
# workflow tolerates its absence the same way.
if grep -q 'd3dcompiler_47\.dll' "$SETUP"; then
	if grep -q 'd3dcompiler_47.dll.*skipifsourcedoesntexist' "$SETUP"; then
		echo "skipped: d3dcompiler_47.dll already optional"
	else
		sed_i 's|\(d3dcompiler_47\.dll.*Flags: ignoreversion\)|\1 skipifsourcedoesntexist|' "$SETUP"
		echo "patched: d3dcompiler_47.dll is optional in the installer"
	fi
else
	fail "no d3dcompiler_47.dll entry in $SETUP — upstream reworked the installer, re-check this patch"
fi

echo "ci-patch: done"
