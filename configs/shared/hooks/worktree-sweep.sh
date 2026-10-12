#!/bin/bash
# Removes linked git worktrees that agents left behind after their work landed.
# Usage: worktree-sweep.sh [--dry-run] [--quiet] [--idle-hours N] [--repo PATH]
#
# A worktree is removed only when it is unlocked, not in use (no live process
# cwd inside it), idle for N hours, and every uncommitted file has been saved
# under <git-common-dir>/worktree-salvage/. A branch is deleted only when all
# of its commits are on the base branch; otherwise it is kept (a detached HEAD
# with unlanded commits gets a salvage/<name> branch).
#
# Wired as an async Claude Code SessionStart hook. Portable to macOS: no
# bash 4 features, and /proc checks are skipped where /proc does not exist.

DRY_RUN=false
QUIET=false
IDLE_HOURS=24
REPO=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --quiet) QUIET=true ;;
        --idle-hours) IDLE_HOURS="${2:-}"; shift ;;
        --repo) REPO="${2:-}"; shift ;;
        *) echo "worktree-sweep: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
case "$IDLE_HOURS" in '' | *[!0-9]*) echo "worktree-sweep: --idle-hours needs a whole number" >&2; exit 2 ;; esac

[ -n "$REPO" ] || REPO="$PWD"
TOP=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || exit 0
COMMON=$(cd "$TOP" && cd "$(git rev-parse --git-common-dir)" && pwd -P) || exit 0

WT_PATH=()
WT_HEAD=()
WT_BRANCH=()
WT_LOCKED=()
WT_SKIP=()
WT_GONE=()
n=-1
cur_path=""
flush_block() {
    [ -n "$cur_path" ] || return 0
    n=$((n + 1))
    WT_PATH[n]="$cur_path"
    WT_HEAD[n]="$cur_head"
    WT_BRANCH[n]="$cur_branch"
    WT_LOCKED[n]="$cur_locked"
    WT_SKIP[n]="$cur_skip"
    WT_GONE[n]=0
    cur_path=""
}
cur_head="" cur_branch="" cur_locked="" cur_skip=""
while IFS= read -r line; do
    case "$line" in
        "worktree "*)
            flush_block
            cur_path="${line#worktree }"
            cur_head="" cur_branch="" cur_locked="" cur_skip="" ;;
        "HEAD "*) cur_head="${line#HEAD }" ;;
        "branch refs/heads/"*) cur_branch="${line#branch refs/heads/}" ;;
        "locked"*) cur_locked=1 ;;
        "bare") cur_skip="bare" ;;
        "prunable"*) cur_skip="prunable" ;;
    esac
done < <(git -C "$TOP" worktree list --porcelain 2>/dev/null)
flush_block

[ "$n" -ge 1 ] || exit 0

BASE=""
if git -C "$TOP" rev-parse --verify -q refs/heads/main >/dev/null; then
    BASE=main
elif git -C "$TOP" rev-parse --verify -q refs/heads/master >/dev/null; then
    BASE=master
else
    origin_head=$(git -C "$TOP" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)
    [ -n "$origin_head" ] && BASE="${origin_head#refs/remotes/}"
fi
if [ -z "$BASE" ]; then
    echo "worktree-sweep: no main, master or origin/HEAD base branch in $TOP, skipping sweep"
    exit 0
fi

LOCKFILE="$COMMON/worktree-sweep.lock"
if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCKFILE"
    flock -n 9 || exit 0
else
    # WHY: stale after a crash, so a lock dir older than an hour is reclaimed.
    if [ -d "$LOCKFILE.d" ] && [ -n "$(find "$LOCKFILE.d" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
        rmdir "$LOCKFILE.d" 2>/dev/null || true
    fi
    mkdir "$LOCKFILE.d" 2>/dev/null || exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/worktree-sweep.XXXXXX")
cleanup() {
    rm -rf "$TMP"
    [ -d "$LOCKFILE.d" ] && rmdir "$LOCKFILE.d" 2>/dev/null
    return 0
}
trap cleanup EXIT

if stat -c %Y / >/dev/null 2>&1; then
    stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
    stat_size() { stat -c %s "$1" 2>/dev/null; }
    stat_mtimes_stdin() { xargs -0 stat -c %Y 2>/dev/null; }
else
    stat_mtime() { stat -f %m "$1" 2>/dev/null; }
    stat_size() { stat -f %z "$1" 2>/dev/null; }
    stat_mtimes_stdin() { xargs -0 stat -f %m 2>/dev/null; }
fi

NOW=$(date +%s)
CUTOFF=$((NOW - IDLE_HOURS * 3600))
TODAY=$(date +%F)
REMOVED=0 KEPT=0 SALVAGED=0 SKIPPED=0
PREFIX=""
$DRY_RUN && PREFIX="would "

say() { $QUIET || printf '%s\n' "$*"; }

LIVE_CWDS=""
if [ -d /proc/self ]; then
    for c in /proc/[0-9]*/cwd; do
        LIVE_CWDS="$LIVE_CWDS$(readlink "$c" 2>/dev/null)"$'\n'
    done
fi

in_use() {
    local wt="$1" c
    case "$PWD/" in "$wt"/*) return 0 ;; esac
    [ -n "$LIVE_CWDS" ] || return 1
    while IFS= read -r c; do
        case "$c/" in "$wt"/*) return 0 ;; esac
    done <<< "$LIVE_CWDS"
    return 1
}

# Writes NUL-separated modified and untracked paths (./-prefixed) to $2.
dirty_paths() {
    local wt="$1" out="$2" entry code skip_next=0
    : > "$out"
    while IFS= read -r -d '' entry; do
        if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
        code="${entry:0:2}"
        case "$code" in *R* | *C*) skip_next=1 ;; esac
        printf './%s\0' "${entry:3}" >> "$out"
    done < <(git --no-optional-locks -C "$wt" status --porcelain -z --untracked-files=all 2>/dev/null)
}

newest_activity() {
    local gitdir="$1" wt="$2" paths="$3" newest=0 m f
    for f in "$gitdir/logs/HEAD" "$gitdir/HEAD"; do
        m=$(stat_mtime "$f")
        [ -n "$m" ] && [ "$m" -gt "$newest" ] && newest="$m"
    done
    if [ -s "$paths" ]; then
        m=$(cd "$wt" && stat_mtimes_stdin < "$paths" | sort -n | tail -1)
        [ -n "$m" ] && [ "$m" -gt "$newest" ] && newest="$m"
    fi
    echo "$newest"
}

# Prints "U <sha>" for commits on $1 that are not on BASE, and "S <sha>" for
# ones that count as landed only because a BASE commit has the same subject and
# author email (squash and rebase merges keep both, but so can unrelated work).
unlanded_commits() {
    local head="$1" sha subj email mb range seen=0
    while IFS= read -r line; do
        [ "${line:0:1}" = "+" ] || continue
        if [ "$seen" = 0 ]; then
            seen=1
            mb=$(git -C "$TOP" merge-base "$BASE" "$head" 2>/dev/null || true)
            range="$BASE"
            [ -n "$mb" ] && range="$mb..$BASE"
            git -C "$TOP" log --format='%ae%x09%s' "$range" > "$TMP/base-subjects" 2>/dev/null
        fi
        sha="${line#+ }"
        email=$(git -C "$TOP" log -1 --format=%ae "$sha")
        subj=$(git -C "$TOP" log -1 --format=%s "$sha")
        if grep -Fxq -- "$email"$'\t'"$subj" "$TMP/base-subjects"; then
            echo "S $sha"
        else
            echo "U $sha"
        fi
    done < <(git -C "$TOP" cherry "$BASE" "$head" 2>/dev/null)
}

salvage_dirty() {
    local wt="$1" name="$2" branch="$3" head="$4" paths="$5" dir f p size
    dir="$COMMON/worktree-salvage/$TODAY/$name"
    [ -e "$dir" ] && dir="$dir-${head:0:7}"
    mkdir -p "$dir" || return 1
    git -C "$wt" diff --binary HEAD > "$dir/tracked.diff" || return 1
    [ -s "$dir/tracked.diff" ] || rm -f "$dir/tracked.diff"
    : > "$TMP/untracked-list"
    : > "$dir/skipped.txt"
    while IFS= read -r -d '' f; do
        p="${f#./}"
        case "/$p" in */.venv/* | */node_modules/* | */target/* | */dist/* | */__pycache__/*) continue ;; esac
        size=$(cd "$wt" && stat_size "$f")
        if [ "${size:-0}" -gt 20971520 ]; then
            printf '%s\n' "$p" >> "$dir/skipped.txt"
            continue
        fi
        printf '%s\0' "$f" >> "$TMP/untracked-list"
    done < <(git -C "$wt" ls-files -z --others --exclude-standard)
    [ -s "$dir/skipped.txt" ] || rm -f "$dir/skipped.txt"
    if [ -s "$TMP/untracked-list" ]; then
        (cd "$wt" && tar --null -czf "$dir/untracked.tar.gz" -T "$TMP/untracked-list") || return 1
    fi
    {
        echo "path: $wt"
        echo "branch: ${branch:-(detached)}"
        echo "head: $head"
        echo "date: $TODAY"
    } > "$dir/info.txt"
    echo "$dir"
}

branch_checked_out_elsewhere() {
    local branch="$1" self="$2" j
    for ((j = 1; j <= n; j++)); do
        [ "$j" = "$self" ] && continue
        [ "${WT_GONE[j]}" = 1 ] && continue
        [ "${WT_BRANCH[j]}" = "$branch" ] && return 0
    done
    return 1
}

i=1
while [ "$i" -le "$n" ]; do
    wt="${WT_PATH[i]}"
    head="${WT_HEAD[i]}"
    branch="${WT_BRANCH[i]}"
    name=$(basename "$wt")
    idx=$i
    i=$((i + 1))

    if [ -n "${WT_SKIP[idx]}" ]; then
        [ "${WT_SKIP[idx]}" = prunable ] || { say "skipped $wt (${WT_SKIP[idx]})"; SKIPPED=$((SKIPPED + 1)); }
        continue
    fi
    if [ -n "${WT_LOCKED[idx]}" ]; then
        say "skipped $wt (locked)"; SKIPPED=$((SKIPPED + 1)); continue
    fi
    if in_use "$wt"; then
        say "skipped $wt (in use by a running process)"; SKIPPED=$((SKIPPED + 1)); continue
    fi
    gitdir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || {
        say "skipped $wt (not readable)"; SKIPPED=$((SKIPPED + 1)); continue
    }
    paths="$TMP/dirty-paths"
    dirty_paths "$wt" "$paths"
    newest=$(newest_activity "$gitdir" "$wt" "$paths")
    if [ "$newest" -gt "$CUTOFF" ]; then
        say "skipped $wt (active within ${IDLE_HOURS}h)"; SKIPPED=$((SKIPPED + 1)); continue
    fi

    landing=$(unlanded_commits "$head")
    unlanded=$(printf '%s\n' "$landing" | sed -n 's/^U //p')
    subject_only=$(printf '%s\n' "$landing" | sed -n 's/^S //p')
    notes=""
    salvage_branch=""
    if [ -n "$unlanded" ]; then
        if [ -z "$branch" ]; then
            salvage_branch="salvage/$name"
            git -C "$TOP" rev-parse --verify -q "refs/heads/$salvage_branch" >/dev/null && salvage_branch="salvage/$name-${head:0:7}"
            notes="$notes, unlanded commits kept on branch $salvage_branch"
        else
            notes="$notes, unlanded commits kept on branch $branch"
        fi
    fi

    if [ -s "$paths" ]; then
        if $DRY_RUN; then
            notes="$notes, uncommitted files would be salvaged"
        else
            dir=$(salvage_dirty "$wt" "$name" "$branch" "$head" "$paths") || {
                say "skipped $wt (could not save uncommitted work)"; SKIPPED=$((SKIPPED + 1)); continue
            }
            notes="$notes, uncommitted files saved to $dir"
        fi
        SALVAGED=$((SALVAGED + 1))
    fi

    if ! $DRY_RUN; then
        if [ -n "$salvage_branch" ]; then
            git -C "$TOP" branch "$salvage_branch" "$head" >/dev/null 2>&1 || {
                say "skipped $wt (could not create $salvage_branch)"; SKIPPED=$((SKIPPED + 1)); continue
            }
        fi
        git -C "$TOP" worktree remove --force "$wt" >/dev/null 2>&1 || {
            say "skipped $wt (git worktree remove failed)"; SKIPPED=$((SKIPPED + 1)); continue
        }
        WT_GONE[idx]=1
    fi
    REMOVED=$((REMOVED + 1))
    [ -n "$salvage_branch" ] && KEPT=$((KEPT + 1))

    if [ -n "$branch" ]; then
        if [ -n "$unlanded" ]; then
            KEPT=$((KEPT + 1))
        elif [ "$branch" = "$BASE" ] || branch_checked_out_elsewhere "$branch" "$idx"; then
            notes="$notes, branch $branch kept (checked out elsewhere)"
        else
            if ! $DRY_RUN; then
                # A subject match can be a different change under the same title, so the
                # head stays reachable from a ref that git branch does not list.
                [ -n "$subject_only" ] && git -C "$TOP" update-ref "refs/worktree-sweep/$branch" "$head"
                mkdir -p "$COMMON/worktree-salvage"
                printf '%s\t%s\t%s\n' "$TODAY" "$branch" "$head" >> "$COMMON/worktree-salvage/deleted-branches.log"
                git -C "$TOP" branch -D "$branch" >/dev/null 2>&1
            fi
            notes="$notes, ${PREFIX}delete branch $branch"
            [ -n "$subject_only" ] && notes="$notes (head kept at refs/worktree-sweep/$branch)"
        fi
    fi
    say "${PREFIX}remove $wt${notes}"
done

$DRY_RUN || git -C "$TOP" worktree prune 2>/dev/null

summary="worktree-sweep: removed $REMOVED, kept branches $KEPT, salvaged $SALVAGED, skipped $SKIPPED"
$DRY_RUN && summary="$summary (dry run, nothing changed)"
if $QUIET; then
    [ "$REMOVED" -gt 0 ] && echo "$summary"
else
    echo "$summary"
fi
exit 0
