#!/usr/bin/env bash
# 统计仓库中每个文件的 git 历史总贡献 top N 开发者
# 用法: ./git-file-contributors.sh [目录或文件列表] [--top N] [--added-lines]

set -euo pipefail

TOP_N=5
COUNT_MODE="commits"  # commits | added-lines
TARGETS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --top)   TOP_N="$2"; shift 2 ;;
        --added-lines) COUNT_MODE="added-lines"; shift ;;
        -h|--help)
            echo "用法: $0 [目录或文件...] [--top N] [--added-lines]"
            echo "  --top N         显示 top N 贡献者 (默认 5)"
            echo "  --added-lines   按添加行数统计 (默认按 commit 数统计)"
            echo "  无参数时统计仓库中所有被 git 跟踪的文件"
            exit 0 ;;
        *) TARGETS="$TARGETS $1"; shift ;;
    esac
done

# 获取所有被跟踪的文件列表
if [[ -z "$TARGETS" ]]; then
    FILES=$(git ls-files)
else
    FILES=""
    for t in $TARGETS; do
        if [[ -d "$t" ]]; then
            FILES="$FILES
$(git ls-files "$t")"
        elif [[ -f "$t" ]]; then
            FILES="$FILES
$t"
        else
            echo "警告: 跳过不存在的路径 $t" >&2
        fi
    done
fi

# 去空行
FILES=$(printf '%s\n' $FILES | grep -v '^$' | sort -u)

if [[ -z "$FILES" ]]; then
    echo "没有找到任何文件" >&2
    exit 1
fi

FILE_COUNT=$(printf '%s\n' "$FILES" | wc -l | tr -d ' ')

echo "=========================================="
echo " Git 文件贡献者统计 (模式: ${COUNT_MODE})"
echo " Top ${TOP_N} per file"
echo " 文件总数: ${FILE_COUNT}"
echo "=========================================="
echo

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "$FILES" | while IFS= read -r file; do
    outfile="${tmpdir}/$(echo "$file" | tr '/' '%')"

    if [[ "$COUNT_MODE" == "commits" ]]; then
        # 统计每个作者对该文件的 commit 数（包含全部历史，包括已删除行）
        git log --follow --format="%aN" -- "$file" 2>/dev/null \
            | sort | uniq -c | sort -rn | head -n "$TOP_N" \
            > "$outfile"
    else
        # 统计每个作者添加的总行数（跨所有历史）
        git log --follow --format="COMMIT:%aN" --numstat -- "$file" 2>/dev/null \
            | awk '
                /^COMMIT:/ { author = substr($0, 8) }
                /^[0-9]/   { added[author] += $1 }
                END {
                    for (a in added)
                        print added[a], a
                }
            ' | sort -rn | head -n "$TOP_N" \
            > "$outfile"
    fi
done

# 输出结果，按文件名排序
echo "$FILES" | while IFS= read -r file; do
    outfile="${tmpdir}/$(echo "$file" | tr '/' '%')"

    if [[ ! -s "$outfile" ]]; then
        continue
    fi

    echo "--- $file ---"
    while IFS=' ' read -r count author; do
        printf "  %-40s %s\n" "$author" "$count"
    done < "$outfile"
    echo
done
