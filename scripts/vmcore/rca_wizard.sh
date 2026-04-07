#!/bin/bash
# rca_wizard.sh - Interactive Root Cause Analysis Wizard

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

prompt() {
    local question="$1"
    local var_name="$2"
    local response=""

    echo -e "${YELLOW}${question}${NC}"
    read -r -p "> " response
    printf -v "$var_name" '%s' "$response"

    echo "$question" >> "$RCA_FILE"
    echo "-> $response" >> "$RCA_FILE"
    echo "" >> "$RCA_FILE"
}

validate() {
    local question="$1"
    local answer=""

    echo -e "${YELLOW}${question}${NC}"
    read -r -p "[Y/N] > " answer
    echo "$question -> $answer" >> "$RCA_FILE"

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

    echo "$title" >> "$RCA_FILE"
    echo "================================================================================" >> "$RCA_FILE"
    echo "" >> "$RCA_FILE"
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

cat > "$RCA_FILE" <<EOF
================================================================================
ROOT CAUSE ANALYSIS REPORT
================================================================================
Date: $(date)
Analyst: $(whoami)
System: $(hostname)

EOF

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

echo "" >> "$RCA_FILE"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "${GREEN}All validation checks passed.${NC}"
    echo "Validation: PASSED" >> "$RCA_FILE"
else
    echo -e "${YELLOW}$FAIL_COUNT validation check(s) failed. More analysis may be needed.${NC}"
    echo "Validation: NEEDS MORE WORK ($FAIL_COUNT failures)" >> "$RCA_FILE"
fi

echo "" >> "$RCA_FILE"

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

cat >> "$RCA_FILE" <<EOF
================================================================================
EXECUTIVE SUMMARY
================================================================================
Symptom: $SYMPTOM
Root cause: $ROOT_CAUSE
Mechanism: $MECHANISM
Scope: $SCOPE

Recommended actions:
  Immediate: $IMMEDIATE_FIX
  Systemic:  $SYSTEMIC_FIX1
             $SYSTEMIC_FIX2
Verification: $VERIFICATION
================================================================================
EOF

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