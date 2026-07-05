#!/bin/bash
# Test: OpenAI Chat Completions Tool Calling Protocol
# Tests the full multi-turn tool calling flow:
# 1. Send request with tools parameter
# 2. Expect tool_calls in response with finish_reason="tool_calls"
# 3. Send follow-up with tool role message containing tool result
# 4. Expect normal text response

set -e

BASE_URL="http://localhost:8230"
SESSION_ID="test-openai-tool-$(date +%s)"
PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

echo "=== OpenAI Tool Calling Test ==="
echo "Session: $SESSION_ID"
echo ""

# Step 1: Send request with tools, expect tool_calls in response
echo "--- Step 1: Request with tools parameter ---"
RESPONSE=$(curl -s "$BASE_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"auto\",
    \"stream\": false,
    \"session_id\": \"$SESSION_ID\",
    \"messages\": [{\"role\":\"user\",\"content\":\"What is the weather in Istanbul? Use the get_weather tool.\"}],
    \"tools\": [
      {
        \"type\": \"function\",
        \"function\": {
          \"name\": \"get_weather\",
          \"description\": \"Get the current weather for a city\",
          \"parameters\": {
            \"type\": \"object\",
            \"properties\": {
              \"city\": {\"type\": \"string\", \"description\": \"The city name\"}
            },
            \"required\": [\"city\"]
          }
        }
      }
    ]
  }")

echo "Response received, parsing..."
FINISH_REASON=$(echo "$RESPONSE" | jq -r '.choices[0].finish_reason // "null"')
TOOL_CALLS=$(echo "$RESPONSE" | jq -r '.choices[0].message.tool_calls // "null"')
CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // "null"')

echo "  finish_reason: $FINISH_REASON"
echo "  tool_calls: $TOOL_CALLS"
echo "  content: ${CONTENT:0:100}..."
echo ""

if [ "$FINISH_REASON" = "tool_calls" ] && [ "$TOOL_CALLS" != "null" ]; then
    pass "Step 1: tool_calls returned with finish_reason=tool_calls"
else
    fail "Step 1: Expected tool_calls + finish_reason=tool_calls, got finish_reason=$FINISH_REASON"
    echo "  Full response: $RESPONSE" | head -c 500
    echo ""
fi

# Extract tool call details for step 2
TOOL_CALL_ID=$(echo "$RESPONSE" | jq -r '.choices[0].message.tool_calls[0].id // "call_test"')
TOOL_CALL_NAME=$(echo "$RESPONSE" | jq -r '.choices[0].message.tool_calls[0].function.name // "get_weather"')
# Keep arguments as a JSON string (escaped), not a raw object
TOOL_CALL_ARGS_JSON=$(echo "$RESPONSE" | jq -c '.choices[0].message.tool_calls[0].function.arguments // "{}"')

echo "  Extracted: id=$TOOL_CALL_ID name=$TOOL_CALL_NAME args=$TOOL_CALL_ARGS_JSON"
echo ""

# Step 2: Send follow-up with tool result
echo "--- Step 2: Follow-up with tool result ---"
# Build the JSON payload using jq to avoid escaping issues
PAYLOAD=$(jq -n \
  --arg sid "$SESSION_ID" \
  --arg tcid "$TOOL_CALL_ID" \
  --arg tcname "$TOOL_CALL_NAME" \
  --argjson tcargs "$TOOL_CALL_ARGS_JSON" \
  '{
    model: "auto",
    stream: false,
    session_id: $sid,
    messages: [
      {role:"user",content:"What is the weather in Istanbul? Use the get_weather tool."},
      {role:"assistant",content:null,tool_calls:[{id:$tcid,type:"function",function:{name:$tcname,arguments:($tcargs|tostring)}}]},
      {role:"tool",tool_call_id:$tcid,content:"Sunny, 25C, humidity 40%"}
    ],
    tools: [
      {
        type: "function",
        function: {
          name: "get_weather",
          description: "Get the current weather for a city",
          parameters: {
            type: "object",
            properties: {
              city: {type: "string", description: "The city name"}
            },
            required: ["city"]
          }
        }
      }
    ]
  }')

RESPONSE2=$(curl -s "$BASE_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD")

echo "Response received, parsing..."
FINISH_REASON2=$(echo "$RESPONSE2" | jq -r '.choices[0].finish_reason // "null"')
CONTENT2=$(echo "$RESPONSE2" | jq -r '.choices[0].message.content // "null"')

echo "  finish_reason: $FINISH_REASON2"
echo "  content: ${CONTENT2:0:200}..."
echo ""

if [ "$FINISH_REASON2" = "stop" ] && [ "$CONTENT2" != "null" ] && [ "$CONTENT2" != "" ]; then
    pass "Step 2: Text response received after tool result"
else
    fail "Step 2: Expected text response with finish_reason=stop, got finish_reason=$FINISH_REASON2"
    echo "  Full response: $RESPONSE2" | head -c 500
    echo ""
fi

echo ""
echo "=== Results: $PASSED passed, $FAILED failed ==="
exit $FAILED
