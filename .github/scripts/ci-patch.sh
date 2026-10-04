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

# jom builds a Qt module's plugins in parallel, and each plugin's qmake writes
# a qt_plugin_*.pri into the module's own mkspecs\modules-inst\ directory,
# creating it first if missing. Those concurrent creates race; the loser dies
# with "Cannot write file ...: Cannot create parent directory" and takes the
# whole Qt stage (and hours of runner time) with it. Pre-creating the
# directories before jom starts makes the create a no-op. The inserted line is
# doubled-backslash because it lands inside a Python string literal, and it
# starts with 'for' so prepare.py's command wrapper does not prefix it with
# 'call' (winFailOnEach in prepare.py).
# The idempotency guard tests for OUR inserted line, not for the bare word
# 'modules-inst'. Upstream hit this same race and, as of tdesktop 7.0.9, works
# around it with `jom || jom` under a `rem ... modules-inst ...` comment. A
# guard on the bare word matches that comment, so this block would report
# "already pre-created" and insert nothing — silently dropping the fix, which
# is the exact failure mode this script exists to avoid. The two mitigations
# are complementary: we stop the race, their retry survives it.
if grep -q 'for %%m in (qtbase' "$PREPARE"; then
	echo "skipped: Qt mkspecs/modules-inst already pre-created"
else
	# awk, not sed: this inserts a line, and sed's 'i' command syntax differs
	# between GNU and BSD.
	#
	# The anchor matches the Qt build invocation by shape, not by exact text:
	# leading whitespace, then `jom -jN`, minus the `rem` comment and the
	# build_libs/clean/install invocations that belong to other stages. That
	# matched the bare line before 7.0.9 and matches `jom -jN || jom -jN`
	# after it, so upstream reworking that command's flags again does not
	# silently skip. Indentation is copied from the matched line, so a
	# re-indent of the stage stays correct too.
	tmp="$(mktemp "$PREPARE.ci-patch.XXXXXX")" || fail "mktemp failed next to $PREPARE"
	awk '
		!done \
		&& /^[[:space:]]*jom -j%NUMBER_OF_PROCESSORS%/ \
		&& $0 !~ /^[[:space:]]*rem/ \
		&& $0 !~ /build_libs/ && $0 !~ /clean/ && $0 !~ /install/ {
			match($0, /^[[:space:]]*/)
			print substr($0, 1, RLENGTH) "for %%m in (qtbase qtimageformats qtsvg) do if not exist %%m\\\\mkspecs\\\\modules-inst mkdir %%m\\\\mkspecs\\\\modules-inst"
			done = 1
		}
		{ print }
	' "$PREPARE" > "$tmp" || { rm -f "$tmp"; fail "awk failed on $PREPARE"; }
	mv "$tmp" "$PREPARE" || { rm -f "$tmp"; fail "could not write $PREPARE"; }
	grep -q 'for %%m in (qtbase' "$PREPARE" \
		|| fail "no Qt 'jom -j%NUMBER_OF_PROCESSORS%' build line in $PREPARE — upstream changed the Qt stage, re-check this patch"
	echo "patched: Qt mkspecs/modules-inst dirs pre-created (parallel qmake race)"
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

# ---------------------------------------------------------------------------
# 4. Cap how many cl.exe run at once.
#
# options_win.cmake compiles with a bare /MP, i.e. one cl.exe per core. Since
# tdesktop 7.0.9 that no longer fits: the build cleared every dependency
# project and then died 1h55m in with 16 x C1060 "compiler is out of heap
# space", all in Telegram.vcxproj, on the heaviest translation units (the
# generated qrc_emoji_*.cpp at 90k+ lines, ayu/libs/json.hpp,
# window_main_menu.cpp). This is NOT the old 32-bit address-space limit:
# build.yml sets PreferredToolArchitecture and the log shows HostX64\x64, so
# it is genuine memory exhaustion on a 4-core runner.
#
# It has to be patched here rather than through MSBuild. /MP arrives as a raw
# compile option in AdditionalOptions, so `/p:CL_MPCount=N` is inert: that
# property only feeds ClCompile's ProcessorNumber, which MSBuild honours
# solely when it owns MultiProcessorCompilation itself. Rewriting the flag is
# the only lever that reaches cl.
#
# Windows-only in effect — this file is included for MSVC builds, so the patch
# is inert on Linux and macOS. It lives in the cmake submodule, so as with
# every other patch here nothing is committed to a tracked file.
# ---------------------------------------------------------------------------

OPTSWIN="cmake/options_win.cmake"
[ -f "$OPTSWIN" ] || fail "$OPTSWIN not found - the cmake submodule is not checked out (clone with --recursive)"

# How many cl.exe may run at once. Overridable so this can be retuned from the
# workflow without editing the patch logic.
#
# The escalation so far, all on the same 4-core runner: bare /MP gave 16 x
# C1060; /MP2 cut that to 3, in the largest translation units (apiwrap.cpp and
# friends); so the heaviest single TU still does not fit in half the box. 1
# gives one compiler the whole machine, which costs wall-clock but is the only
# setting with no concurrent peak at all. Disk is no longer the constraint --
# the cleanup step in build.yml leaves 41.4 GB free and C1085 is gone.
MP_COUNT="${CI_MSVC_MP:-1}"
case "$MP_COUNT" in
	''|*[!0-9]*|0) fail "CI_MSVC_MP must be a positive integer, got '$MP_COUNT'" ;;
esac

if grep -qE '^[[:space:]]*/MP[0-9]' "$OPTSWIN"; then
	echo "skipped: MSVC compiler count already capped"
elif grep -qE '^[[:space:]]*/MP([[:space:]]|$)' "$OPTSWIN"; then
	# Two expressions rather than one \b: BSD sed has no word-boundary escape.
	# Neither can rematch afterwards, since /MPn is /MP followed by a digit.
	sed_i 's|^\([[:space:]]*\)/MP\([[:space:]]\)|\1/MP'"$MP_COUNT"'\2|' "$OPTSWIN"
	sed_i 's|^\([[:space:]]*\)/MP$|\1/MP'"$MP_COUNT"'|' "$OPTSWIN"
	grep -qE '^[[:space:]]*/MP[0-9]' "$OPTSWIN" \
		|| fail "could not cap /MP in $OPTSWIN"
	echo "patched: MSVC compiler count capped (/MP -> /MP$MP_COUNT, C1060 out-of-heap)"
else
	fail "no bare '/MP' flag in $OPTSWIN - upstream changed the MSVC options, re-check this patch"
fi

# ---------------------------------------------------------------------------
# 5. Point "get the update" at OUR releases.
#
# Autoupdate is compiled out, and tdesktop already handles that case: when
# UpdaterDisabled() is true it stops trying to self-update and just opens a
# download page instead (update_checker.cpp, UpdateApplication). AyuGram points
# that page, and the "Update AyuGram" button shown on messages too new for the
# running build, at their own release channel. Ours are not their builds, so
# send users somewhere that actually has the binary they are running.
#
# This is the whole of our update story by design: no signing key, no silent
# background rewrite of the installed files, no Updater.exe. The user clicks a
# link, downloads the installer, and runs it -- and the installer upgrades in
# place without touching tdata (see section 6).
#
# Deliberately NOT the /releases/latest URL: the rolling 'continuous' release
# can be flagged prerelease, and /latest then 404s or silently serves an older
# tag. The plain list always shows the newest first.
# ---------------------------------------------------------------------------

RELEASES_URL="${CI_RELEASES_URL:-https://github.com/purr/AyuGramDesktop/releases}"
UPDATE_LINK_FILES="Telegram/SourceFiles/core/update_checker.cpp Telegram/SourceFiles/history/history_item_helpers.cpp"

for f in $UPDATE_LINK_FILES; do
	[ -f "$f" ] || fail "$f not found - wrong root?"
done

STALE=0
for f in $UPDATE_LINK_FILES; do
	n=$(grep -c 'https://t\.me/AyuGramReleases' "$f" || true)
	STALE=$((STALE + n))
done

if [ "$STALE" -gt 0 ]; then
	for f in $UPDATE_LINK_FILES; do
		sed_i "s|https://t\.me/AyuGramReleases|$RELEASES_URL|g" "$f"
	done
	for f in $UPDATE_LINK_FILES; do
		if grep -q 'https://t\.me/AyuGramReleases' "$f"; then
			fail "could not repoint the update links in $f"
		fi
	done
	echo "patched: $STALE update link(s) -> $RELEASES_URL"
else
	OURS=0
	for f in $UPDATE_LINK_FILES; do
		if grep -qF "$RELEASES_URL" "$f"; then
			OURS=1
		fi
	done
	if [ "$OURS" -eq 1 ]; then
		echo "skipped: update links already point at our releases"
	else
		fail "no AyuGramReleases link in $UPDATE_LINK_FILES - upstream changed the update links, re-check this patch"
	fi
fi

# ---------------------------------------------------------------------------
# 6. Drop a stale Updater.exe on upgrade.
#
# Section 3 removes Updater.exe from [Files] because DESKTOP_APP_DISABLE_AUTOUPDATE
# never builds it. But installing over an OFFICIAL AyuGram install leaves theirs
# behind: [Files] only overwrites what it ships, so an unlisted binary survives.
# It is inert in our builds -- nothing invokes it -- but a stray updater sitting
# in the install directory is exactly the kind of thing this fork exists to not
# have. [InstallDelete] runs before the files are copied, on every install.
#
# Only {app}\Updater.exe is touched. Nothing here goes near tdata: user data is
# not in [Files] and so is never rewritten by an upgrade, and the [UninstallDelete]
# list that DOES name tdata only runs on uninstall.
# ---------------------------------------------------------------------------

if grep -q '^\[InstallDelete\]' "$SETUP"; then
	echo "skipped: stale Updater.exe already cleaned on upgrade"
elif grep -q '^\[Icons\]' "$SETUP"; then
	tmp="$(mktemp "$SETUP.ci-patch.XXXXXX")" || fail "mktemp failed next to $SETUP"
	awk '
		/^\[Icons\]/ && !done {
			print "[InstallDelete]"
			print "; ci-patch: autoupdate is compiled out, so a Updater.exe left by an"
			print "; official AyuGram install would just sit there unused."
			print "Type: files; Name: \"{app}\\Updater.exe\""
			print ""
			done = 1
		}
		{ print }
	' "$SETUP" > "$tmp" || { rm -f "$tmp"; fail "awk failed on $SETUP"; }
	mv "$tmp" "$SETUP" || { rm -f "$tmp"; fail "could not write $SETUP"; }
	grep -q '^\[InstallDelete\]' "$SETUP" \
		|| fail "could not add [InstallDelete] to $SETUP"
	echo "patched: stale Updater.exe removed on upgrade"
else
	fail "no [Icons] section in $SETUP - upstream reworked the installer, re-check this patch"
fi

echo "ci-patch: done"
