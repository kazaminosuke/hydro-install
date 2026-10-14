#!/usr/bin/env python3
"""Mutation check for the mock test suites.

Each mutation breaks one safety rule in a scratch copy of the repository and
runs the mock suites. A mutation that no suite notices ("survived") is a gap
in the tests. Exit status is 1 when any mutation survives or no longer
applies (the code it targets changed and this list needs updating).

Usage: python3 tests/mutation-check.py [-k substring]
"""
import os, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITES = ["tests/wings-layout-test.sh", "tests/security-defaults-test.sh",
          "tests/update-safety-test.sh", "tests/script-loading-test.sh"]

# (name, file, original text, mutated text)
# Not listed on purpose: dropping the "namespaced" guard in
# wings_migrate_validate is an equivalent mutant; the hydrodactyl-wings binary,
# config and data-directory checks right below it refuse the same case.
MUTATIONS = [
    ("Pelican config tree no longer foreign", "lib/wings-layout.sh",
     "    /etc/pelican|/etc/pelican/*|\\\n", "    /etc/pelican-x|\\\n"),
    ("owned legacy service may always be stopped", "lib/wings-layout.sh",
     '    hydro-legacy)\n      [ "$service" = "wings" ] && return 0\n      return 1',
     '    hydro-legacy)\n      return 0'),
    ("foreign service is stoppable", "lib/wings-layout.sh",
     "    *)\n      return 1\n      ;;\n  esac\n}\n\nwings_address_in_use()",
     "    *)\n      return 0\n      ;;\n  esac\n}\n\nwings_address_in_use()"),
    ("subnet overlap ignored", "lib/wings-layout.sh",
     "      if wings_ipv4_cidr_overlaps \"$value\" \"$existing\"; then",
     "      if false; then"),
    ("bridge falls back to pterodactyl0", "lib/wings-layout.sh",
     "printf 'hydro%s\\n' \"${suffix:-0}\"", "printf 'pterodactyl0\\n'"),
    ("Wings-RS network mode not rewritten", "lib/wings-layout.sh",
     "name|network_mode|mode)", "name|network_mode)"),
    ("container stop failure swallowed", "lib/wings-layout.sh",
     'return "$failed"', "return 0"),
    ("migration copies live containers", "lib/wings-layout.sh",
     '  wings_stop_containers_using "$root_dir" || return 1\n', ""),
    ("rollback leaves legacy Wings stopped", "lib/wings-layout.sh",
     '  if [ "$was_active" = 1 ]; then\n    wings_systemctl start wings',
     '  if false; then\n    wings_systemctl start wings'),
    ("runtime collisions never reported", "lib/wings-layout.sh",
     '        *"$token"*)\n          printf', '        *"$token-never"*)\n          printf'),
    ("Go Wings version subcommand not tried", "lib/wings-layout.sh",
     '    out=$("$binary" version 2>/dev/null | head -n 1) || out=""', '    out=""'),
    ("MariaDB always binds every interface", "lib/lib.sh",
     "    printf '%s\\n' \"127.0.0.1\"", "    printf '%s\\n' \"0.0.0.0\""),
    ("defaults file loses quote escaping", "lib/lib.sh",
     '  escaped=${escaped//\\"/\\\\\\"}\n  printf \'[client]', "  printf '[client]"),
    ("socket unit keeps ListenStream=3306", "lib/lib.sh",
     "ListenStream=\nListenStream=@mariadb", "ListenStream=@mariadb"),
    ("download failure ignored by get_script", "lib/lib.sh",
     '    if ! curl -fsSL -o "$tmp_script" "$GITHUB_URL/$script_type/$script_name.sh" 2>/dev/null || [ ! -s "$tmp_script" ]; then',
     '    if false; then'),
    ("writable or symlinked /tmp library accepted", "lib/lib.sh",
     '  [ -f "$file" ] && [ ! -L "$file" ] || return 1\n  [ -z "$(find "$file" -perm /022 2>/dev/null)" ] || return 1\n',
     '  [ -e "$file" ] || return 1\n'),
    ("another user's /tmp library accepted", "lib/lib.sh",
     '  [ -O "$file" ] && return 0\n', '  return 0\n'),
    ("buffer pool not capped", "lib/lib.sh",
     '  [ "$mb" -gt 1024 ] && mb=1024\n', ""),
    ("updater backups world-readable", "installers/auto-update-panel.sh",
     '  mkdir -p "$BACKUP_DIR"\n  chmod 700 "$BACKUP_DIR"\n\n  local timestamp',
     '  mkdir -p "$BACKUP_DIR"\n\n  local timestamp'),
    ("Wings updater uses upstream main", "installers/auto-update-wings.sh",
     '  local url="${GITHUB_BASE_URL:-https://raw.githubusercontent.com/itzzjustmateo/hydro-install}/${GITHUB_SOURCE:-main}/lib/wings-layout.sh"',
     '  local url="https://raw.githubusercontent.com/itzzjustmateo/hydro-install/${GITHUB_SOURCE:-main}/lib/wings-layout.sh"'),
]


def run_suites(tree):
    for suite in SUITES:
        r = subprocess.run(["bash", os.path.join(tree, suite)], cwd=tree,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=600)
        if r.returncode != 0:
            return suite
    return None


def main():
    only = sys.argv[2] if len(sys.argv) > 2 and sys.argv[1] == "-k" else None
    scratch = tempfile.mkdtemp()
    tree = os.path.join(scratch, "repo")
    shutil.copytree(ROOT, tree, ignore=shutil.ignore_patterns(".git"))
    baseline = run_suites(tree)
    if baseline:
        print(f"baseline failed in {baseline}; fix the suites first")
        return 2
    bad = 0
    for name, rel, old, new in MUTATIONS:
        if only and only not in name:
            continue
        path = os.path.join(tree, rel)
        with open(path) as f:
            original = f.read()
        if original.count(old) != 1:
            print(f"STALE    {name} ({rel}: target text found {original.count(old)} times)")
            bad += 1
            continue
        with open(path, "w") as f:
            f.write(original.replace(old, new, 1))
        try:
            caught = run_suites(tree)
        finally:
            with open(path, "w") as f:
                f.write(original)
        if caught:
            print(f"killed   {name} (by {caught})")
        else:
            print(f"SURVIVED {name}")
            bad += 1
    shutil.rmtree(scratch)
    print(f"{len(MUTATIONS)} mutations, {bad} survived or stale")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
