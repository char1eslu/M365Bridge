#!/bin/bash
# Test: Anthropic Messages API Tool Use Protocol
# Tests the full multi-turn tool use flow:
# 1. Send request with tools parameter
# 2. Expect tool_use content block in response with stop_reason="tool_use"
# 3. Send follow-up with tool_result content block
# 4. Expect normal text response

set -e

BASE_URL="http://localhost:8230"
SESSION_ID="test-anthropic-tool-$(date +%s)"
PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

echo "=== Anthropic Tool Use Test ==="
echo "Session: $SESSION_ID"
echo ""

# Step 1: Send request with tools, expect tool_use in response
echo "--- Step 1: Request with tools parameter ---"
RESPONSE=$(curl -s "$BASE_URL/v1/messages" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d "{
    \"model\": \"auto\",
    \"max_tokens\": 1024,
    \"session_id\": \"$SESSION_ID\",
    \"messages\": [{\"role\":\"user\",\"content\":\"What is the weather in Istanbul? Use the get_weather tool.\"}],
    \"tools\": [
      {
        \"name\": \"get_weather\",
        \"description\": \"Get the current weather for a city\",
        \"input_schema\": {
          \"type\": \"object\",
          \"properties\": {
            \"city\": {\"type\": \"string\", \"description\": \"The city name\"}
          },
          \"required\": [\"city\"]
        }
      }
    ]
  }")

echo "Response received, parsing..."
STOP_REASON=$(echo "$RESPONSE" | jq -r '.stop_reason // "null"')
TOOL_USE_BLOCKS=$(echo "$RESPONSE" | jq -r '[.content[] | select(.type=="tool_use")] | length')
TEXT_BLOCK=$(echo "$RESPONSE" | jq -r '[.content[] | select(.type=="text")] | .[0].text // "null"')

echo "  stop_reason: $STOP_REASON"
echo "  tool_use blocks: $TOOL_USE_BLOCKS"
echo "  text: ${TEXT_BLOCK:0:100}..."
echo ""

if [ "$STOP_REASON" = "tool_use" ] && [ "$TOOL_USE_BLOCKS" -ge 1 ] 2>/dev/null; then
    pass "Step 1: tool_use block returned with stop_reason=tool_use"
else
    fail "Step 1: Expected tool_use + stop_reason=tool_use, got stop_reason=$STOP_REASON tool_use_blocks=$TOOL_USE_BLOCKS"
    echo "  Full response: $RESPONSE" | head -c 500
    echo ""
fi

# Extract tool use details for step 2
TOOL_USE_ID=$(echo "$RESPONSE" | jq -r '.content[] | select(.type=="tool_use") | .id // "toolu_test"')
TOOL_USE_NAME=$(echo "$RESPONSE" | jq -r '.content[] | select(.type=="tool_use") | .name // "get_weather"')
TOOL_USE_INPUT=$(echo "$RESPONSE" | jq -r '.content[] | select(.type=="tool_use") | .input // "{}"')

echo "  Extracted: id=$TOOL_USE_ID name=$TOOL_USE_NAME input=$TOOL_USE_INPUT"
echo ""

# Step 2: Send follow-up with tool_result
echo "--- Step 2: Follow-up with tool_result ---"
RESPONSE2=$(curl -s "$BASE_URL/v1/messages" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d "{
    \"model\": \"auto\",
    \"max_tokens\": 1024,
    \"session_id\": \"$SESSION_ID\",
    \"messages\": [
      {\"role\":\"user\",\"content\":\"What is the weather in Istanbul? Use the get_weather tool.\"},
      {\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"$TOOL_USE_ID\",\"name\":\"$TOOL_USE_NAME\",\"input\":$TOOL_USE_INPUT}]},
      {\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$TOOL_USE_ID\",\"content\":\"Sunny, 25C, humidity 40%\"}]}
    ],
    \"tools\": [
      {
        \"name\": \"get_weather\",
        \"description\": \"Get the current weather for a city\",
        \"input_schema\": {
          \"type\": \"object\",
          \"properties\": {
            \"city\": {\"type\": \"string\", \"description\": \"The city name\"}
          },
          \"required\": [\"city\"]
        }
      }
    ]
  }")

echo "Response received, parsing..."
STOP_REASON2=$(echo "$RESPONSE2" | jq -r '.stop_reason // "null"')
CONTENT2=$(echo "$RESPONSE2" | jq -r '[.content[] | select(.type=="text")] | .[0].text // "null"')

echo "  stop_reason: $STOP_REASON2"
echo "  content: ${CONTENT2:0:200}..."
echo ""

if [ "$STOP_REASON2" = "end_turn" ] && [ "$CONTENT2" != "null" ] && [ "$CONTENT2" != "" ]; then
    pass "Step 2: Text response received after tool_result"
else
    fail "Step 2: Expected text response with stop_reason=end_turn, got stop_reason=$STOP_REASON2"
    echo "  Full response: $RESPONSE2" | head -c 500
    echo ""
fi

echo ""
echo "=== Results: $PASSED passed, $FAILED failed ==="
exit $FAILED
