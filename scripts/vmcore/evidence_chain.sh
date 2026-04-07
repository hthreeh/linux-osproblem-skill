#!/bin/bash
# evidence_chain.sh - Build and verify an evidence chain for RCA

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
EVIDENCE_DIR="${HOME}/evidence_chains"
EVIDENCE_FILE="${EVIDENCE_DIR}/evidence_${TIMESTAMP}.txt"

PROMPT_ANSWER=""
PROMPT_EVIDENCE=""

mkdir -p "$EVIDENCE_DIR"

clear_screen() {
    if command -v clear >/dev/null 2>&1 && [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
        clear
    fi
}

prompt_evidence() {
    local level="$1"
    local question="$2"
    local evidence_question="$3"
    local answer=""
    local evidence=""

    echo ""
    echo -e "${BLUE}================================================================================${NC}"
    echo -e "${GREEN}${level}${NC}"
    echo -e "${BLUE}================================================================================${NC}"
    echo -e "${YELLOW}${question}${NC}"
    read -r -p "> " answer
    echo -e "${YELLOW}${evidence_question}${NC}"
    read -r -p "> " evidence

    PROMPT_ANSWER="$answer"
    PROMPT_EVIDENCE="$evidence"

    cat >> "$EVIDENCE_FILE" <<EOF
$level
================================================================================
Finding: $answer
Evidence: $evidence

EOF
}

verify() {
    local question="$1"
    local answer=""

    echo -e "${CYAN}${question}${NC}"
    read -r -p "[Y/N] > " answer
    echo "$question -> $answer" >> "$EVIDENCE_FILE"

    if [[ "$answer" =~ ^[Yy] ]]; then
        return 0
    fi
    return 1
}

clear_screen
cat <<EOF
================================================================================
EVIDENCE CHAIN BUILDER
================================================================================
Build a chain from symptom to direct cause, mechanism, design flaw, and root cause.
Every step should cite concrete evidence.

Report path: $EVIDENCE_FILE
EOF

cat > "$EVIDENCE_FILE" <<EOF
================================================================================
EVIDENCE CHAIN REPORT
================================================================================
Date: $(date)
Analyst: $(whoami)

Principle: every conclusion must be backed by concrete evidence.

EOF

echo -e "${MAGENTA}Building evidence chain...${NC}"

prompt_evidence "Level 0: Symptom" "What did the user or system observe?" "What concrete evidence supports this observation?"
SYMPTOM="$PROMPT_ANSWER"
SYMPTOM_EVIDENCE="$PROMPT_EVIDENCE"

prompt_evidence "Level 1: Proximate Cause" "What immediate technical cause is visible in the dump or logs?" "Which output proves it?"
PROXIMATE="$PROMPT_ANSWER"
PROXIMATE_EVIDENCE="$PROMPT_EVIDENCE"

prompt_evidence "Level 2: Mechanism" "How did the proximate cause happen?" "Which structure, code path, or log sequence proves it?"
MECHANISM="$PROMPT_ANSWER"
MECHANISM_EVIDENCE="$PROMPT_EVIDENCE"

prompt_evidence "Level 3: Design Flaw" "What design or implementation weakness allowed this mechanism?" "Which code, config, or architecture evidence proves it?"
DESIGN_FLAW="$PROMPT_ANSWER"
DESIGN_FLAW_EVIDENCE="$PROMPT_EVIDENCE"

prompt_evidence "Level 4: Root Cause" "What systemic issue allowed the design flaw to exist?" "What evidence supports that broader conclusion?"
ROOT_CAUSE="$PROMPT_ANSWER"
ROOT_CAUSE_EVIDENCE="$PROMPT_EVIDENCE"

echo ""
echo -e "${BLUE}================================================================================${NC}"
echo -e "${GREEN}Call Chain${NC}"
echo -e "${BLUE}================================================================================${NC}"
echo -e "${CYAN}Enter one call-chain step per line. Submit an empty line to finish.${NC}"

echo "Call Chain" >> "$EVIDENCE_FILE"
echo "================================================================================" >> "$EVIDENCE_FILE"
CALL_CHAIN_LINES=()
while true; do
    local_line=""
    read -r -p "call chain > " local_line
    if [ -z "$local_line" ]; then
        break
    fi
    CALL_CHAIN_LINES+=("$local_line")
    echo "$local_line" >> "$EVIDENCE_FILE"
done
echo "" >> "$EVIDENCE_FILE"

echo ""
echo -e "${BLUE}================================================================================${NC}"
echo -e "${GREEN}Timeline${NC}"
echo -e "${BLUE}================================================================================${NC}"

echo "Timeline" >> "$EVIDENCE_FILE"
echo "================================================================================" >> "$EVIDENCE_FILE"
for event in "System start" "First symptom" "Escalation" "Crash"; do
    time_point=""
    read -r -p "$event > " time_point
    echo "$event: $time_point" >> "$EVIDENCE_FILE"
done
echo "" >> "$EVIDENCE_FILE"

cat >> "$EVIDENCE_FILE" <<EOF
================================================================================
EVIDENCE CHAIN VISUALIZATION
================================================================================
[Symptom]        $SYMPTOM
  Evidence:      $SYMPTOM_EVIDENCE
[Direct Cause]   $PROXIMATE
  Evidence:      $PROXIMATE_EVIDENCE
[Mechanism]      $MECHANISM
  Evidence:      $MECHANISM_EVIDENCE
[Design Flaw]    $DESIGN_FLAW
  Evidence:      $DESIGN_FLAW_EVIDENCE
[Root Cause]     $ROOT_CAUSE
  Evidence:      $ROOT_CAUSE_EVIDENCE
================================================================================
EOF

echo -e "${YELLOW}Verify the chain quality.${NC}"
PASS_COUNT=0
TOTAL_COUNT=8
if verify "Does every level have concrete evidence?"; then ((++PASS_COUNT)); fi
if verify "Can the call chain be verified from a stack trace?"; then ((++PASS_COUNT)); fi
if verify "Can the data state be verified from structures or logs?"; then ((++PASS_COUNT)); fi
if verify "Can the suspected code path be verified from code or disassembly?"; then ((++PASS_COUNT)); fi
if verify "Can the timeline be reconstructed from logs or events?"; then ((++PASS_COUNT)); fi
if verify "Are the links between levels logically connected?"; then ((++PASS_COUNT)); fi
if verify "Would another engineer reach the same conclusion from this evidence?"; then ((++PASS_COUNT)); fi
if verify "Does this chain rule out the main alternative explanations?"; then ((++PASS_COUNT)); fi

echo "" >> "$EVIDENCE_FILE"
echo "Verification score: $PASS_COUNT / $TOTAL_COUNT" >> "$EVIDENCE_FILE"
echo "" >> "$EVIDENCE_FILE"

echo -e "${YELLOW}Explain this in plain language.${NC}"
read -r -p "Analogy > " ANALOGY
read -r -p "One-line executive summary > " EXEC_SUMMARY

cat >> "$EVIDENCE_FILE" <<EOF
================================================================================
PLAIN LANGUAGE SUMMARY
================================================================================
Executive summary: $EXEC_SUMMARY
Analogy: $ANALOGY

In plain language:
The system showed "$SYMPTOM" because "$PROXIMATE" happened.
That happened through "$MECHANISM".
The deeper weakness was "$DESIGN_FLAW".
The systemic root cause was "$ROOT_CAUSE".
================================================================================
EOF

echo ""
echo -e "${GREEN}Evidence chain complete.${NC}"
echo -e "Report saved to: ${CYAN}${EVIDENCE_FILE}${NC}"
echo "Verification score: $PASS_COUNT / $TOTAL_COUNT"