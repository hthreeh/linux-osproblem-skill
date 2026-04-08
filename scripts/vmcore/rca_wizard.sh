#!/bin/bash
# rca_wizard.sh - Interactive Root Cause Analysis Wizard
# 用法:
#   交互模式: rca_wizard.sh
#   批处理模式: rca_wizard.sh --batch <input_file>
#   输入文件格式: KEY=VALUE，每行一个
#     SYMPTOM=...
#     WHEN_OCCURRED=...
#     FREQUENCY=...
#     WORKLOAD=...
#     PANIC_MSG=...
#     CRASH_FUNC=...
#     CRASH_ADDR=...
#     WHY1=... WHY2=... WHY3=... WHY4=... WHY5=...
#     EVIDENCE1=... EVIDENCE2=... EVIDENCE3=... EVIDENCE4=...
#     ALT1=... ALT1_DISPROOF=...
#     ALT2=... ALT2_DISPROOF=...
#     ROOT_CAUSE=... MECHANISM=... SYSTEMIC_ISSUE=... SCOPE=...
#     IMMEDIATE_FIX=... SYSTEMIC_FIX1=... SYSTEMIC_FIX2=... VERIFICATION=...

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RCA_DIR="${HOME}/rca_reports"
RCA_FILE="${RCA_DIR}/rca_${TIMESTAMP}.txt"

mkdir -p "$RCA_DIR"

clear_screen() {
    if command -v clear >/dev/null 2>&1 && [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
        clear
    fi
}

# =====================================================================
# 批处理模式
# =====================================================================
run_batch() {
    local input_file="$1"

    if [ ! -f "$input_file" ]; then
        echo "错误: 输入文件不存在: $input_file" >&2
        exit 1
    fi

    # 读取所有 KEY=VALUE
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # 清理 Windows 回车符
        key="${key//$'\r'/}"
        value="${value//$'\r'/}"
        # 跳过空行和注释
        [ -z "$key" ] && continue
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        # 去除首尾空白
        key=$(echo "$key" | xargs)
        [ -z "$key" ] && continue
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # 设置变量
        export "$key=$value"
    done < "$input_file"

    # 写入报告
    write_rca_report

    echo "批处理模式完成，报告: $RCA_FILE"
    exit 0
}

write_rca_report() {
    # 报告头
    {
        printf '%s\n' "================================================================================"
        printf '%s\n' "ROOT CAUSE ANALYSIS REPORT"
        printf '%s\n' "================================================================================"
        printf 'Date: %s\n' "$(date)"
        printf 'Analyst: %s (batch mode)\n' "$(whoami)"
        printf 'System: %s\n' "$(hostname)"
        printf '\n'
    } > "$RCA_FILE"

    # SECTION 1
    write_section "SECTION 1: BASIC INFORMATION"
    {
        printf 'What is the observable symptom?\n-> %s\n\n' "${SYMPTOM:-N/A}"
        printf 'When did this occur?\n-> %s\n\n' "${WHEN_OCCURRED:-N/A}"
        printf 'How often does this occur?\n-> %s\n\n' "${FREQUENCY:-N/A}"
        printf 'What was the system doing at the time?\n-> %s\n\n' "${WORKLOAD:-N/A}"
    } >> "$RCA_FILE"

    # SECTION 2
    write_section "SECTION 2: INITIAL FINDINGS"
    {
        printf 'What panic / error message do you see?\n-> %s\n\n' "${PANIC_MSG:-N/A}"
        printf 'Which function appears at the crash site?\n-> %s\n\n' "${CRASH_FUNC:-N/A}"
        printf 'What address or object looks suspicious?\n-> %s\n\n' "${CRASH_ADDR:-N/A}"
    } >> "$RCA_FILE"

    # SECTION 3: 5 Whys
    write_section "SECTION 3: THE 5 WHYS"
    {
        printf '1. Why did the crash occur?\n-> %s\n\n' "${WHY1:-N/A}"
        printf '2. Why did that condition exist?\n-> %s\n\n' "${WHY2:-N/A}"
        printf '3. Why was that possible?\n-> %s\n\n' "${WHY3:-N/A}"
        printf '4. Why was it not prevented earlier?\n-> %s\n\n' "${WHY4:-N/A}"
        printf '5. What systemic issue made this possible?\n-> %s\n\n' "${WHY5:-N/A}"
    } >> "$RCA_FILE"

    # SECTION 4
    write_section "SECTION 4: SUPPORTING EVIDENCE"
    {
        printf 'Evidence #1\n-> %s\n\n' "${EVIDENCE1:-N/A}"
        printf 'Evidence #2\n-> %s\n\n' "${EVIDENCE2:-N/A}"
        printf 'Evidence #3\n-> %s\n\n' "${EVIDENCE3:-N/A}"
        printf 'Evidence #4 (optional)\n-> %s\n\n' "${EVIDENCE4:-N/A}"
    } >> "$RCA_FILE"

    # SECTION 5
    write_section "SECTION 5: ALTERNATIVE HYPOTHESES"
    {
        printf 'Alternative hypothesis #1\n-> %s\n' "${ALT1:-N/A}"
        printf 'Why is hypothesis #1 disproven?\n-> %s\n\n' "${ALT1_DISPROOF:-N/A}"
        printf 'Alternative hypothesis #2\n-> %s\n' "${ALT2:-N/A}"
        printf 'Why is hypothesis #2 disproven?\n-> %s\n\n' "${ALT2_DISPROOF:-N/A}"
    } >> "$RCA_FILE"

    # SECTION 6
    write_section "SECTION 6: VALIDATION CHECKLIST"
    {
        printf 'Validation: PASSED (batch mode, auto-passed)\n\n'
    } >> "$RCA_FILE"

    # SECTION 7
    write_section "SECTION 7: ROOT CAUSE STATEMENT"
    {
        printf 'Root cause\n-> %s\n\n' "${ROOT_CAUSE:-N/A}"
        printf 'Mechanism\n-> %s\n\n' "${MECHANISM:-N/A}"
        printf 'Systemic issue\n-> %s\n\n' "${SYSTEMIC_ISSUE:-N/A}"
        printf 'Scope\n-> %s\n\n' "${SCOPE:-N/A}"
    } >> "$RCA_FILE"

    # SECTION 8
    write_section "SECTION 8: RECOMMENDED ACTIONS"
    {
        printf 'Immediate fix\n-> %s\n\n' "${IMMEDIATE_FIX:-N/A}"
        printf 'Systemic fix #1\n-> %s\n\n' "${SYSTEMIC_FIX1:-N/A}"
        printf 'Systemic fix #2\n-> %s\n\n' "${SYSTEMIC_FIX2:-N/A}"
        printf 'How will you verify the fix?\n-> %s\n\n' "${VERIFICATION:-N/A}"
    } >> "$RCA_FILE"

    # Executive Summary
    {
        printf '%s\n' "================================================================================"
        printf '%s\n' "EXECUTIVE SUMMARY"
        printf '%s\n' "================================================================================"
        printf 'Symptom: %s\n' "${SYMPTOM:-N/A}"
        printf 'Root cause: %s\n' "${ROOT_CAUSE:-N/A}"
        printf 'Mechanism: %s\n' "${MECHANISM:-N/A}"
        printf 'Scope: %s\n' "${SCOPE:-N/A}"
        printf '\nRecommended actions:\n'
        printf '  Immediate: %s\n' "${IMMEDIATE_FIX:-N/A}"
        printf '  Systemic:  %s\n' "${SYSTEMIC_FIX1:-N/A}"
        printf '             %s\n' "${SYSTEMIC_FIX2:-N/A}"
        printf 'Verification: %s\n' "${VERIFICATION:-N/A}"
        printf '%s\n' "================================================================================"
    } >> "$RCA_FILE"
}

write_section() {
    local title="$1"
    printf '\n%s\n' "$title" >> "$RCA_FILE"
    printf '%s\n' "================================================================================" >> "$RCA_FILE"
    printf '\n' >> "$RCA_FILE"
}

# 解析命令行参数
BATCH_MODE=0
BATCH_INPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --batch|-b)
            BATCH_MODE=1
            BATCH_INPUT="$2"
            shift 2
            ;;
        --help|-h)
            echo "用法: $0 [--batch <input_file>]"
            echo "  无参数: 交互模式"
            echo "  --batch <file>: 批处理模式，从文件读取 KEY=VALUE 输入"
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            exit 1
            ;;
    esac
done

if [ "$BATCH_MODE" -eq 1 ]; then
    run_batch "$BATCH_INPUT"
fi

# =====================================================================
# 交互模式（原有逻辑）
# =====================================================================

prompt() {
    local question="$1"
    local var_name="$2"
    local response=""

    echo -e "${YELLOW}${question}${NC}"
    read -r -p "> " response
    printf -v "$var_name" '%s' "$response"

    # 使用 printf 安全写入，避免变量展开导致命令注入
    printf '%s\n' "$question" >> "$RCA_FILE"
    printf '-> %s\n' "$response" >> "$RCA_FILE"
    printf '\n' >> "$RCA_FILE"
}

validate() {
    local question="$1"
    local answer=""

    echo -e "${YELLOW}${question}${NC}"
    read -r -p "[Y/N] > " answer
    printf '%s -> %s\n' "$question" "$answer" >> "$RCA_FILE"

    if [[ "$answer" =~ ^[Yy] ]]; then
        return 0
    fi
    return 1
}

begin_section() {
    local title="$1"
    echo ""
    echo -e "${BLUE}================================================================================${NC}"
    echo -e "${GREEN}${title}${NC}"
    echo -e "${BLUE}================================================================================${NC}"
    echo ""

    printf '%s\n' "$title" >> "$RCA_FILE"
    printf '%s\n' "================================================================================" >> "$RCA_FILE"
    printf '\n' >> "$RCA_FILE"
}

clear_screen
cat <<EOF
================================================================================
ROOT CAUSE ANALYSIS WIZARD
================================================================================
This wizard walks through a structured RCA process.
Every claim should be backed by evidence from crash output, logs, code, or config.

Report path: $RCA_FILE
EOF

echo ""
read -r -p "Press Enter to continue..."

cat > "$RCA_FILE" <<'HEADER'
================================================================================
ROOT CAUSE ANALYSIS REPORT
================================================================================
HEADER
{
    printf 'Date: %s\n' "$(date)"
    printf 'Analyst: %s\n' "$(whoami)"
    printf 'System: %s\n' "$(hostname)"
    printf '\n'
} >> "$RCA_FILE"

begin_section "SECTION 1: BASIC INFORMATION"
prompt "What is the observable symptom?" SYMPTOM
prompt "When did this occur?" WHEN_OCCURRED
prompt "How often does this occur?" FREQUENCY
prompt "What was the system doing at the time?" WORKLOAD

begin_section "SECTION 2: INITIAL FINDINGS"
prompt "What panic / error message do you see?" PANIC_MSG
prompt "Which function appears at the crash site?" CRASH_FUNC
prompt "What address or object looks suspicious?" CRASH_ADDR

begin_section "SECTION 3: THE 5 WHYS"
prompt "1. Why did the crash occur?" WHY1
prompt "2. Why did that condition exist?" WHY2
prompt "3. Why was that possible?" WHY3
prompt "4. Why was it not prevented earlier?" WHY4
prompt "5. What systemic issue made this possible?" WHY5

echo -e "${CYAN}Checkpoint: answer #5 should describe a systemic issue, not just a symptom.${NC}"
read -r -p "Press Enter to continue..."

begin_section "SECTION 4: SUPPORTING EVIDENCE"
prompt "Evidence #1" EVIDENCE1
prompt "Evidence #2" EVIDENCE2
prompt "Evidence #3" EVIDENCE3
prompt "Evidence #4 (optional)" EVIDENCE4

begin_section "SECTION 5: ALTERNATIVE HYPOTHESES"
prompt "Alternative hypothesis #1" ALT1
prompt "Why is hypothesis #1 disproven?" ALT1_DISPROOF
prompt "Alternative hypothesis #2" ALT2
prompt "Why is hypothesis #2 disproven?" ALT2_DISPROOF

begin_section "SECTION 6: VALIDATION CHECKLIST"
FAIL_COUNT=0
if ! validate "Can you show the exact state that triggered the failure?"; then ((++FAIL_COUNT)); fi
if ! validate "Can you trace the sequence of calls that led here?"; then ((++FAIL_COUNT)); fi
if ! validate "Does the explanation account for all observations?"; then ((++FAIL_COUNT)); fi
if ! validate "Is the proposed root cause specific enough to guide a fix?"; then ((++FAIL_COUNT)); fi
if ! validate "Would the fix prevent this class of failures?"; then ((++FAIL_COUNT)); fi
if ! validate "Could another engineer reproduce the same conclusion from the evidence?"; then ((++FAIL_COUNT)); fi

printf '\n' >> "$RCA_FILE"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "${GREEN}All validation checks passed.${NC}"
    printf '%s\n' "Validation: PASSED" >> "$RCA_FILE"
else
    echo -e "${YELLOW}$FAIL_COUNT validation check(s) failed. More analysis may be needed.${NC}"
    printf 'Validation: NEEDS MORE WORK (%d failures)\n' "$FAIL_COUNT" >> "$RCA_FILE"
fi

printf '\n' >> "$RCA_FILE"

begin_section "SECTION 7: ROOT CAUSE STATEMENT"
prompt "Root cause" ROOT_CAUSE
prompt "Mechanism" MECHANISM
prompt "Systemic issue" SYSTEMIC_ISSUE
prompt "Scope" SCOPE

begin_section "SECTION 8: RECOMMENDED ACTIONS"
prompt "Immediate fix" IMMEDIATE_FIX
prompt "Systemic fix #1" SYSTEMIC_FIX1
prompt "Systemic fix #2" SYSTEMIC_FIX2
prompt "How will you verify the fix?" VERIFICATION

# 使用 printf 安全写入执行摘要
{
    printf '%s\n' "================================================================================"
    printf '%s\n' "EXECUTIVE SUMMARY"
    printf '%s\n' "================================================================================"
    printf 'Symptom: %s\n' "$SYMPTOM"
    printf 'Root cause: %s\n' "$ROOT_CAUSE"
    printf 'Mechanism: %s\n' "$MECHANISM"
    printf 'Scope: %s\n' "$SCOPE"
    printf '\n'
    printf 'Recommended actions:\n'
    printf '  Immediate: %s\n' "$IMMEDIATE_FIX"
    printf '  Systemic:  %s\n' "$SYSTEMIC_FIX1"
    printf '             %s\n' "$SYSTEMIC_FIX2"
    printf 'Verification: %s\n' "$VERIFICATION"
    printf '%s\n' "================================================================================"
} >> "$RCA_FILE"

echo ""
echo -e "${GREEN}Root cause analysis complete.${NC}"
echo -e "Report saved to: ${CYAN}${RCA_FILE}${NC}"
echo ""
echo "Executive summary:"
echo "  Symptom:    $SYMPTOM"
echo "  Root cause: $ROOT_CAUSE"
echo "  Scope:      $SCOPE"

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Warning: validation reported $FAIL_COUNT gap(s).${NC}"
fi