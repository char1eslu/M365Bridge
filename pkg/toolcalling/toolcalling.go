// Package toolcalling provides simulated tool calling support for clients
// (Claude Code, Codex, etc.) by injecting tool definitions into the message
// text sent to M365 Copilot and parsing tool call patterns from the response.
//
// M365 Copilot backend does not natively support client-defined tools.
// This package bridges the gap by:
//   - Injecting tool definitions as a system prompt prefix into the last user message
//   - Parsing tool call JSON blocks from M365 response text
//   - Converting tool role messages (OpenAI) and tool_result blocks (Anthropic)
//     back into text for the M365 backend
package toolcalling

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// ToolDef represents a tool definition from the client request.
type ToolDef struct {
	Type     string      `json:"type"`
	Function ToolDefFunc `json:"function"`
	// Anthropic-style fields (flat, no "function" wrapper)
	Name        string                 `json:"name,omitempty"`
	Description string                 `json:"description,omitempty"`
	InputSchema map[string]interface{} `json:"input_schema,omitempty"`
}

// ToolDefFunc is the OpenAI-style function definition inside a tool.
type ToolDefFunc struct {
	Name        string                 `json:"name"`
	Description string                 `json:"description"`
	Parameters  map[string]interface{} `json:"parameters"`
}

// ToolCall represents a parsed tool call from the M365 response.
type ToolCall struct {
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

// toolCallIDCounter generates sequential tool call IDs.
var toolCallIDCounter int

// nextToolCallID returns a unique tool call ID.
func nextToolCallID() string {
	toolCallIDCounter++
	return fmt.Sprintf("call_%d", toolCallIDCounter)
}

// toolCallPattern matches JSON blocks wrapped in <tool>...</tool> tags.
var toolCallPattern = regexp.MustCompile(`(?s)<tool>\s*(\{.*?\})\s*</tool>`)

// InjectTools prepends tool definitions and instructions to the last user message.
// Returns the modified message text. If no tools are provided, returns the original text.
func InjectTools(messages []string, tools []ToolDef) []string {
	if len(tools) == 0 || len(messages) == 0 {
		return messages
	}

	instruction := buildToolInstruction(tools)
	result := make([]string, len(messages))
	copy(result, messages)

	// Find the last user message and prepend the tool instruction
	for i := len(result) - 1; i >= 0; i-- {
		result[i] = instruction + "\n\n" + result[i]
		break
	}

	return result
}

// buildToolInstruction creates the system prompt that tells the model about client-side
// tools and the format to use when requesting the client to execute them.
//
// The prompt uses "coordinator/delegation" framing: the model has NO filesystem access
// and CANNOT execute these tools itself. The tools run on the CLIENT side. The model
// must REQUEST the client to perform actions by emitting <tool> blocks.
//
// This framing is critical because M365 Copilot has its own server-side tools
// (code_interpreter, search). Without explicitly telling the model "you CANNOT do
// this yourself, REQUEST the client", the backend routes file operations to its own
// code_interpreter sandbox instead of emitting a tool call for the client.
func buildToolInstruction(tools []ToolDef) string {
	var sb strings.Builder

	sb.WriteString("=== CLIENT-SIDE TOOL USE PROTOCOL ===\n\n")

	sb.WriteString("IMPORTANT: You are acting as a coordinator. You do NOT have direct access to a filesystem, ")
	sb.WriteString("code execution environment, or any of the tools listed below. These tools are executed by ")
	sb.WriteString("the CLIENT (the application on the user's computer). Your role is to REQUEST the client to ")
	sb.WriteString("perform actions on your behalf.\n\n")

	sb.WriteString("You CANNOT read files, write files, or list directories yourself. ")
	sb.WriteString("You do NOT have access to code_interpreter or any sandbox for these operations. ")
	sb.WriteString("When you need to perform an action that requires a tool, you must REQUEST it from the client.\n\n")

	sb.WriteString("=== HOW TO REQUEST A TOOL ===\n\n")
	sb.WriteString("To request the client to execute a tool, output a tool request block in this exact format:\n")
	sb.WriteString("<tool>{\"name\":\"tool_name\",\"arguments\":{\"key\":\"value\"}}</tool>\n\n")

	sb.WriteString("The client will:\n")
	sb.WriteString("1. Parse your tool request\n")
	sb.WriteString("2. Execute the tool on the user's machine\n")
	sb.WriteString("3. Send you the result in the next message\n\n")

	sb.WriteString("=== RULES ===\n\n")
	sb.WriteString("1. When the user's request requires reading/writing files or listing directories, you MUST emit a <tool> block to request the client to do it.\n")
	sb.WriteString("2. Do NOT attempt to use code_interpreter, search, or any of your built-in tools for file operations. You CANNOT access the filesystem.\n")
	sb.WriteString("3. Do NOT say \"I don't have access to this tool\" or \"this tool is not available\". The tools below ARE available — on the CLIENT side. Request them.\n")
	sb.WriteString("4. Do NOT try to simulate or approximate the tool result yourself. Request the tool and wait for the client's response.\n")
	sb.WriteString("5. The tool request MUST be wrapped in <tool> and </tool> tags. Do NOT use markdown code fences.\n")
	sb.WriteString("6. The JSON inside must have \"name\" and \"arguments\" fields. Arguments must be a JSON object matching the tool's parameters.\n")
	sb.WriteString("7. You may include a brief explanation before the tool request block.\n")
	sb.WriteString("8. Emit only ONE tool request per response. Wait for the client's result before continuing.\n\n")

	sb.WriteString("=== EXAMPLE ===\n\n")
	sb.WriteString("User: Read the file /home/user/config.json\n")
	sb.WriteString("Assistant: I'll request the client to read that file for me.\n")
	sb.WriteString("<tool>{\"name\":\"read_file\",\"arguments\":{\"path\":\"/home/user/config.json\"}}</tool>\n\n")

	sb.WriteString("=== AVAILABLE CLIENT-SIDE TOOLS ===\n\n")

	for _, tool := range tools {
		name := tool.Function.Name
		desc := tool.Function.Description
		params := tool.Function.Parameters

		// Handle Anthropic-style flat definition
		if name == "" {
			name = tool.Name
			desc = tool.Description
			params = tool.InputSchema
		}

		if name == "" {
			continue
		}

		sb.WriteString(fmt.Sprintf("Tool: %s\n", name))
		if desc != "" {
			sb.WriteString(fmt.Sprintf("Description: %s\n", desc))
		}
		if params != nil {
			if paramBytes, err := json.Marshal(params); err == nil {
				sb.WriteString(fmt.Sprintf("Parameters: %s\n", string(paramBytes)))
			}
		}
		sb.WriteString("\n")
	}

	sb.WriteString("=== END TOOL DEFINITIONS ===\n\n")
	sb.WriteString("Remember: You CANNOT execute these tools yourself. REQUEST the client by emitting a <tool> block. ")
	sb.WriteString("Do NOT use code_interpreter or search for file operations. Do NOT refuse.\n")

	return sb.String()
}

// ParseToolCalls scans response text for <tool> blocks and extracts them.
// Returns the text with tool call blocks removed and the parsed tool calls.
// If no tool call blocks are found, returns the original text and nil.
func ParseToolCalls(text string) (string, []ToolCall) {
	matches := toolCallPattern.FindAllStringSubmatch(text, -1)
	if len(matches) == 0 {
		return text, nil
	}

	var calls []ToolCall
	for _, m := range matches {
		if len(m) < 2 {
			continue
		}

		var parsed struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal([]byte(m[1]), &parsed); err != nil {
			continue
		}
		if parsed.Name == "" {
			continue
		}

		calls = append(calls, ToolCall{
			ID:        nextToolCallID(),
			Name:      parsed.Name,
			Arguments: parsed.Arguments,
		})
	}

	if len(calls) == 0 {
		return text, nil
	}

	// Remove tool call blocks from text
	cleaned := toolCallPattern.ReplaceAllString(text, "")
	cleaned = strings.TrimSpace(cleaned)

	return cleaned, calls
}

// FormatToolResult converts a tool result (from the client) into text
// that the M365 backend can understand in the next message.
func FormatToolResult(toolCallID, toolName, result string) string {
	return fmt.Sprintf("[Tool Result for %s (call_id: %s)]\n%s", toolName, toolCallID, result)
}

// FormatAssistantToolCall converts a previous assistant tool call (from conversation
// history) into text that the M365 backend can understand.
func FormatAssistantToolCall(toolName string, arguments json.RawMessage) string {
	return fmt.Sprintf("[Previous Tool Call: %s]\nArguments: %s", toolName, string(arguments))
}
