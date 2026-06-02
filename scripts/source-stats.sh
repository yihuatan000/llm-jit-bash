#!/bin/bash
# source-stats.sh — Scan a project directory and generate source code statistics.
# Compatible with bash 3.2+ (macOS / Linux).
#
# Usage: source-stats.sh [-v] [-n TOP_N] <directory>
#   -v        Verbose: print per-file details
#   -n N      Show top N files per metric (default 15)

set -uo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
VERBOSE=0
TOP_N=15
SCAN_DIR="."
SKIP_DIRS=".git node_modules vendor build dist __pycache__ .tox target .gradle .idea .vscode autom4te.cache"

# ── Parse arguments ────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        -v)  VERBOSE=1; shift ;;
        -n)  TOP_N="$2"; shift 2 ;;
        -*)  echo "Unknown flag: $1" >&2; exit 1 ;;
        *)   SCAN_DIR="$1"; shift ;;
    esac
done

if [ ! -d "$SCAN_DIR" ]; then
    echo "Error: '$SCAN_DIR' is not a directory" >&2
    exit 1
fi

# ── Temp files ────────────────────────────────────────────────────────────
# Per-file data: ext<TAB>code<TAB>comment<TAB>blank<TAB>long_lines<TAB>bytes<TAB>filepath
DATA_FILE=$(mktemp /tmp/source-stats.XXXXXX)
TODO_FILE=$(mktemp /tmp/source-stats-todo.XXXXXX)
trap 'rm -f "$DATA_FILE" "$TODO_FILE"' EXIT

# ── Known extensions ──────────────────────────────────────────────────────
KNOWN_EXTS="c h cpp hpp cc java py rb rs go js ts jsx tsx sh bash yaml yml toml sql css scss html xml md makefile dockerfile"

is_source_ext() {
    local ext="$1" e
    for e in $KNOWN_EXTS; do
        [ "$ext" = "$e" ] && return 0
    done
    return 1
}

should_skip_dir() {
    local d="$1" skip
    for skip in $SKIP_DIRS; do
        [ "$d" = "$skip" ] && return 0
    done
    return 1
}

get_ext() {
    local base="${1##*/}"
    if [[ "$base" == *.* ]]; then
        local ext="${base##*.}"
        echo "$ext" | tr '[:upper:]' '[:lower:]'
        return
    fi
    echo ""
}

# ── Analyze a single file ─────────────────────────────────────────────────
# Pre-compute comment markers as globals to avoid repeated lookups.
LINE_PREFIX=""
BLOCK_OPEN=""
BLOCK_CLOSE=""
HAS_LINE=0
HAS_BLOCK=0

setup_comment_markers() {
    local ext="$1"
    HAS_LINE=0
    HAS_BLOCK=0
    LINE_PREFIX=""
    BLOCK_OPEN=""
    BLOCK_CLOSE=""

    case "$ext" in
        sh|bash|py|rb|yaml|yml|toml|makefile|dockerfile)
            LINE_PREFIX="#"
            HAS_LINE=1
            ;;
        c|cpp|h|hpp|cc|java|rs|go|js|ts|jsx|tsx)
            LINE_PREFIX="//"
            BLOCK_OPEN="/*"
            BLOCK_CLOSE="*/"
            HAS_LINE=1
            HAS_BLOCK=1
            ;;
        css|scss)
            BLOCK_OPEN="/*"
            BLOCK_CLOSE="*/"
            HAS_BLOCK=1
            ;;
        html|xml|md)
            BLOCK_OPEN="<!--"
            BLOCK_CLOSE="-->"
            HAS_BLOCK=1
            ;;
        sql)
            LINE_PREFIX="--"
            HAS_LINE=1
            ;;
    esac
}

analyze_file() {
    local filepath="$1"
    local ext="$2"
    local code=0 comment=0 blank=0 long_lines=0 line_num=0 in_block=0

    local filesize
    filesize=$(wc -c < "$filepath" | tr -d ' ')

    setup_comment_markers "$ext"

    local line trimmed len
    while IFS= read -r line || [ -n "$line" ]; do
        line_num=$(( line_num + 1 ))

        # Line length check
        len=${#line}
        if [ "$len" -gt 120 ]; then
            long_lines=$(( long_lines + 1 ))
        fi

        # Trim leading whitespace using parameter expansion (no subshell)
        trimmed="${line#"${line%%[![:space:]]*}"}"
        # Trim trailing whitespace
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

        # Blank
        if [ -z "$trimmed" ]; then
            blank=$(( blank + 1 ))
            continue
        fi

        # Inside a block comment
        if [ "$in_block" -eq 1 ]; then
            case "$trimmed" in
                *"$BLOCK_CLOSE"*) in_block=0 ;;
            esac
            comment=$(( comment + 1 ))
            continue
        fi

        # Check for block comment open
        if [ "$HAS_BLOCK" -eq 1 ]; then
            case "$trimmed" in
                "$BLOCK_OPEN"*)
                    case "$trimmed" in
                        *"$BLOCK_CLOSE"*) ;;
                        *) in_block=1 ;;
                    esac
                    comment=$(( comment + 1 ))
                    continue
                    ;;
            esac
        fi

        # Check for line comment
        if [ "$HAS_LINE" -eq 1 ]; then
            case "$trimmed" in
                "$LINE_PREFIX"*)
                    comment=$(( comment + 1 ))
                    continue
                    ;;
            esac
        fi

        # Code line — check for TODO/FIXME/HACK/XXX via case (no subshell)
        code=$(( code + 1 ))
        case "$trimmed" in
            [Tt][Oo][Dd][Oo]*|[Ff][Ii][Xx][Mm][Ee]*|[Hh][Aa][Cc][Kk]*|[Xx][Xx][Xx]*)
                local display_line="$line"
                if [ ${#display_line} -gt 80 ]; then
                    display_line="${display_line:0:77}..."
                fi
                printf "%s\t%s\t%s\n" "$filepath" "$line_num" "$display_line" >> "$TODO_FILE"
                ;;
        esac
    done < "$filepath"

    printf "%s\t%d\t%d\t%d\t%d\t%d\t%s\n" \
        "$ext" "$code" "$comment" "$blank" "$long_lines" "$filesize" "$filepath" \
        >> "$DATA_FILE"
}

# ── Collect files recursively ─────────────────────────────────────────────
collect_files() {
    local dir="$1" item ext dirname
    for item in "$dir"/*; do
        [ -e "$item" ] || continue
        if [ -d "$item" ]; then
            dirname="${item##*/}"
            should_skip_dir "$dirname" && continue
            collect_files "$item"
        elif [ -f "$item" ]; then
            ext=$(get_ext "$item")
            if is_source_ext "$ext"; then
                analyze_file "$item" "$ext"
            fi
        fi
    done
}

# ── Formatting helpers ───────────────────────────────────────────────────
fmt_num() {
    echo "$1"
}

fmt_size() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(( bytes / 1073741824 ))G"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(( bytes / 1048576 ))M"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(( bytes / 1024 ))K"
    else
        echo "${bytes}B"
    fi
}

bar() {
    local value=$1 max=$2 width=${3:-30}
    local filled=0
    [ "$max" -gt 0 ] && filled=$(( value * width / max ))
    local i result=""
    for (( i=0; i<filled; i++ )); do result="${result}#"; done
    for (( i=filled; i<width; i++ )); do result="${result}-"; done
    echo "$result"
}

separator() {
    local i s=""
    for (( i=0; i<72; i++ )); do s="${s}-"; done
    echo "$s"
}

# ── Main ──────────────────────────────────────────────────────────────────
echo "Scanning: $SCAN_DIR"
echo "Collecting source files..."
collect_files "$SCAN_DIR"

TOTAL_FILES=$(wc -l < "$DATA_FILE" | tr -d ' ')
if [ "$TOTAL_FILES" -eq 0 ]; then
    echo "No source files found."
    exit 0
fi

TOTAL_CODE=0
TOTAL_COMMENT=0
TOTAL_BLANK=0
TOTAL_BYTES=0
while IFS=$'\t' read -r ext code comment blank long_lines bytes filepath; do
    TOTAL_CODE=$(( TOTAL_CODE + code ))
    TOTAL_COMMENT=$(( TOTAL_COMMENT + comment ))
    TOTAL_BLANK=$(( TOTAL_BLANK + blank ))
    TOTAL_BYTES=$(( TOTAL_BYTES + bytes ))
done < "$DATA_FILE"
TOTAL_LINES=$(( TOTAL_CODE + TOTAL_COMMENT + TOTAL_BLANK ))

# ── Report: Overview ─────────────────────────────────────────────────────
echo ""
separator
echo "  SOURCE CODE STATISTICS REPORT"
echo "  Directory: $SCAN_DIR"
separator
echo ""
printf "  %-20s %s\n" "Files scanned:" "$(fmt_num $TOTAL_FILES)"
printf "  %-20s %s\n" "Total lines:" "$(fmt_num $TOTAL_LINES)"
printf "  %-20s %s\n" "Code lines:" "$(fmt_num $TOTAL_CODE)"
printf "  %-20s %s\n" "Comment lines:" "$(fmt_num $TOTAL_COMMENT)"
printf "  %-20s %s\n" "Blank lines:" "$(fmt_num $TOTAL_BLANK)"
printf "  %-20s %s\n" "Total size:" "$(fmt_size $TOTAL_BYTES)"
if [ "$TOTAL_CODE" -gt 0 ]; then
    ratio=$(( TOTAL_COMMENT * 100 / (TOTAL_CODE + TOTAL_COMMENT) ))
    printf "  %-20s %d%%\n" "Comment ratio:" "$ratio"
fi

# ── Report: Breakdown by extension ──────────────────────────────────────
echo ""
separator
echo "  BREAKDOWN BY FILE TYPE"
separator
echo ""
printf "  %-10s %8s %8s %8s %8s %10s\n" "Ext" "Files" "Code" "Comment" "Blank" "Size"
printf "  %-10s %8s %8s %8s %8s %10s\n" "---" "-----" "----" "-------" "-----" "----"

AGG_FILE=$(mktemp /tmp/source-stats-agg.XXXXXX)
awk -F'\t' '{
    ext=$1; code=$2; comment=$3; blank=$4; bytes=$6
    e_code[ext]+=code; e_comment[ext]+=comment; e_blank[ext]+=blank
    e_bytes[ext]+=bytes; e_files[ext]+=1
}
END {
    for (ext in e_code) {
        total=e_code[ext]+e_comment[ext]+e_blank[ext]
        printf "%d\t%s\t%d\t%d\t%d\t%d\t%d\n", total, ext, e_files[ext], e_code[ext], e_comment[ext], e_blank[ext], e_bytes[ext]
    }
}' "$DATA_FILE" | sort -t"	" -k1,1rn > "$AGG_FILE"

AGG_MAX=$(awk -F'\t' 'BEGIN{m=0} {if($1>m) m=$1} END{print m+0}' "$AGG_FILE")

while IFS=$'\t' read -r total ext files code comment blank bytes; do
    printf "  %-10s %8s %8s %8s %8s %10s\n" \
        ".$ext" \
        "$(fmt_num $files)" \
        "$(fmt_num $code)" \
        "$(fmt_num $comment)" \
        "$(fmt_num $blank)" \
        "$(fmt_size $bytes)"
    printf "  %s\n" "$(bar $total $AGG_MAX 50)"
done < "$AGG_FILE"
rm -f "$AGG_FILE"

# ── Report: Top files by total lines ─────────────────────────────────────
echo ""
separator
echo "  TOP $TOP_N FILES BY TOTAL LINES"
separator
echo ""
printf "  %-6s %-8s %-8s %-8s %s\n" "Lines" "Code" "Comment" "Blank" "File"
printf "  %-6s %-8s %-8s %-8s %s\n" "-----" "----" "-------" "-----" "----"

sort -t"	" -k2,2rn -k3,3rn "$DATA_FILE" | head -n "$TOP_N" | while IFS=$'\t' read -r ext code comment blank long_lines bytes filepath; do
    total=$(( code + comment + blank ))
    relpath="${filepath#$SCAN_DIR/}"
    printf "  %-6s %-8s %-8s %-8s %s\n" \
        "$(fmt_num $total)" \
        "$(fmt_num $code)" \
        "$(fmt_num $comment)" \
        "$(fmt_num $blank)" \
        "$relpath"
done

# ── Report: Files with most long lines ───────────────────────────────────
echo ""
separator
echo "  TOP $TOP_N FILES WITH MOST LONG LINES (>120 chars)"
separator
echo ""

LONG_FILE=$(mktemp /tmp/source-stats-long.XXXXXX)
awk -F'\t' '$5>0{print $5 "\t" $2+$3+$4 "\t" $7}' "$DATA_FILE" | sort -t"	" -k1,1rn > "$LONG_FILE"

LONG_COUNT=$(wc -l < "$LONG_FILE" | tr -d ' ')
if [ "$LONG_COUNT" -gt 0 ]; then
    printf "  %-8s %-10s %s\n" "Long" "% of total" "File"
    printf "  %-8s %-10s %s\n" "----" "---------" "----"
    head -n "$TOP_N" "$LONG_FILE" | while IFS=$'\t' read -r ll total filepath; do
        relpath="${filepath#$SCAN_DIR/}"
        [ "$total" -gt 0 ] && pct=$(( ll * 100 / total )) || pct=0
        printf "  %-8s %-10s %s\n" "$ll" "${pct}%" "$relpath"
    done
else
    echo "  No files with lines exceeding 120 characters."
fi
rm -f "$LONG_FILE"

# ── Report: TODO / FIXME markers ─────────────────────────────────────────
echo ""
separator
echo "  TODO / FIXME / HACK / XXX MARKERS"
separator
echo ""

TODO_COUNT=$(wc -l < "$TODO_FILE" | tr -d ' ')
echo "  Found: $TODO_COUNT"
echo ""

if [ "$TODO_COUNT" -gt 0 ]; then
    head -n 100 "$TODO_FILE" | while IFS=$'\t' read -r filepath lnum text; do
        relpath="${filepath#$SCAN_DIR/}"
        printf "  %-40s L%-5s %s\n" "$relpath" "$lnum" "$text"
    done
    [ "$TODO_COUNT" -gt 100 ] && echo "  ... and $(( TODO_COUNT - 100 )) more"
else
    echo "  No TODO/FIXME/HACK/XXX markers found."
fi

# ── Verbose: per-file details ─────────────────────────────────────────────
if [ "$VERBOSE" -eq 1 ]; then
    echo ""
    separator
    echo "  VERBOSE: ALL FILES"
    separator
    echo ""
    printf "  %-6s %-8s %-8s %-8s %s\n" "Lines" "Code" "Comment" "Blank" "File"
    printf "  %-6s %-8s %-8s %-8s %s\n" "-----" "----" "-------" "-----" "----"
    sort -t"	" -k2,2rn -k3,3rn "$DATA_FILE" | while IFS=$'\t' read -r ext code comment blank long_lines bytes filepath; do
        total=$(( code + comment + blank ))
        relpath="${filepath#$SCAN_DIR/}"
        printf "  %-6s %-8s %-8s %-8s %s\n" \
            "$(fmt_num $total)" \
            "$(fmt_num $code)" \
            "$(fmt_num $comment)" \
            "$(fmt_num $blank)" \
            "$relpath"
    done
fi

echo ""
separator
echo "  Done."
separator
