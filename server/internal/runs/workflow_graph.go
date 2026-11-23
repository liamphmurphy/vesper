package runs

import (
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

// A workflow graph is plain data: the editor, a persona's proposed edits and
// the engine all go through the same validation.

const (
	NodeTrigger = "trigger"
	NodeEnrich  = "enrich"
	NodeAgent   = "agent"
	NodeGate    = "gate"
	NodeWiki    = "wiki"
	NodeLibrary = "library"
	NodeTicket  = "ticket"
	NodeChat    = "chat"

	workflowMaxNodes    = 50
	workflowMaxEdges    = 200
	workflowMaxConfig   = 20000
	workflowMaxAttempts = 5

	workflowCheckPassed = "passed"
	workflowCheckFailed = "failed"
)

var workflowOutputTypes = []string{NodeWiki, NodeLibrary, NodeTicket, NodeChat}
var workflowNodeTypes = append([]string{NodeTrigger, NodeEnrich, NodeAgent, NodeGate}, workflowOutputTypes...)

// WorkflowConfig holds every node type's settings; each type reads only its own.
type WorkflowConfig struct {
	// Prompt is an enrich or agent step's instructions, a gate's message, or an
	// output's body. An empty output body uses what the node's parents produced.
	Prompt      string `json:"prompt,omitempty" jsonschema:"Instructions for enrich and agent; message for gate; body template for outputs (empty uses the parents' output). Supports {{input}} and {{node_id.output}}"`
	PersonaID   string `json:"persona_id,omitempty" jsonschema:"agent: a persona's id to run as; empty uses the chat's persona"`
	AgentHandle string `json:"agent_handle,omitempty" jsonschema:"agent: the @handle of a persona that works (takes tickets or helps on runs), to run with its work definition (harness, model, work brief, scopes) instead of as a chat persona"`
	Web         bool   `json:"web,omitempty" jsonschema:"agent: read the web. A web step can't read the workspace"`
	Images      bool   `json:"images,omitempty" jsonschema:"agent: generate images. The step runs as a persona allowed to make images, on image_engine; not available with agent_handle"`
	// ImageEngine picks the engine an images step runs on.
	ImageEngine string   `json:"image_engine,omitempty" jsonschema:"agent with images: auto (default; the first connected of Codex, Antigravity, and Gemini API), codex, antigravity or gemini. Defaults to the persona's, then the workspace's, engine"`
	Show        []string `json:"show,omitempty" jsonschema:"gate: ids of upstream nodes whose output the reviewer sees; empty shows the gate's parents"`
	Check       bool     `json:"check,omitempty" jsonschema:"agent: this step is a check that reports pass or fail. Unless it passes, nothing after it runs, apart from a gate tied to it with requires_check"`
	RetryFrom   string   `json:"retry_from,omitempty" jsonschema:"gate: id of an upstream enrich or agent node to re-run on Request changes; empty offers only approve or reject. agent with check: the upstream node to re-run automatically when the check fails; empty doesn't retry"`
	MaxAttempts int      `json:"max_attempts,omitempty" jsonschema:"gate: how many reviews before Request changes stops being offered, 1 to 5; default 3. agent with check: how many failures end the retries, 1 to 5; default 3"`
	// RequiresCheck leaves the gate open to Request changes and Reject while the check has failed.
	RequiresCheck string `json:"requires_check,omitempty" jsonschema:"gate: id of a check connected directly into this gate. Approve is refused unless it passed. If the gate has retry_from, re-running must include the check"`
	Path          string `json:"path,omitempty" jsonschema:"wiki: page path, e.g. Research/Findings"`
	Mode          string `json:"mode,omitempty" jsonschema:"wiki: replace (default) or append"`
	Title         string `json:"title,omitempty" jsonschema:"library and ticket: the item's title"`
}

type WorkflowNode struct {
	ID     string         `json:"id"`
	Type   string         `json:"type" jsonschema:"trigger, enrich, agent, gate, wiki, library, ticket or chat"`
	Title  string         `json:"title"`
	X      float64        `json:"x,omitempty"`
	Y      float64        `json:"y,omitempty"`
	Config WorkflowConfig `json:"config"`
}

type WorkflowEdge struct {
	From string `json:"from"`
	To   string `json:"to"`
}

type WorkflowGraph struct {
	Nodes []WorkflowNode `json:"nodes"`
	Edges []WorkflowEdge `json:"edges"`
}

// WorkflowIssue is one reason a graph can't be published. Node is empty for the graph as a whole.
type WorkflowIssue struct {
	Node    string `json:"node,omitempty"`
	Message string `json:"message"`
}

// WorkflowOp is one edit in a persona's proposal.
type WorkflowOp struct {
	Op     string        `json:"op" jsonschema:"add_node, update_node, remove_node, add_edge or remove_edge"`
	Node   *WorkflowNode `json:"node,omitempty" jsonschema:"The whole node, for add_node and update_node"`
	NodeID string        `json:"node_id,omitempty" jsonschema:"For remove_node"`
	From   string        `json:"from,omitempty" jsonschema:"For add_edge and remove_edge"`
	To     string        `json:"to,omitempty" jsonschema:"For add_edge and remove_edge"`
}

var (
	workflowIDRe  = regexp.MustCompile(`^[a-z][a-z0-9_]{0,39}$`)
	workflowVarRe = regexp.MustCompile(`\{\{\s*([a-z][a-z0-9_]*)(?:\.output)?\s*\}\}`)
)

// NewWorkflowGraph is where every new workflow starts.
func NewWorkflowGraph() WorkflowGraph {
	return WorkflowGraph{Nodes: []WorkflowNode{{ID: "trigger", Type: NodeTrigger, Title: "Chat message", X: 40, Y: 200}}, Edges: []WorkflowEdge{}}
}

// ParseWorkflowGraph reads a stored or submitted graph.
func ParseWorkflowGraph(raw []byte) (WorkflowGraph, error) {
	var g WorkflowGraph
	if err := json.Unmarshal(raw, &g); err != nil {
		return g, apperr.Invalid("graph", "isn't a valid workflow graph")
	}
	if g.Nodes == nil {
		g.Nodes = []WorkflowNode{}
	}
	if g.Edges == nil {
		g.Edges = []WorkflowEdge{}
	}
	return g, nil
}

// checkWorkflowBounds keeps even a draft a sane size; ValidateWorkflow is the full check.
func checkWorkflowBounds(g WorkflowGraph) error {
	if len(g.Nodes) > workflowMaxNodes {
		return apperr.Invalid("graph", "a workflow can have at most %d nodes", workflowMaxNodes)
	}
	if len(g.Edges) > workflowMaxEdges {
		return apperr.Invalid("graph", "a workflow can have at most %d connections", workflowMaxEdges)
	}
	for _, n := range g.Nodes {
		c := n.Config
		if utf8.RuneCountInString(n.Title) > 80 || utf8.RuneCountInString(c.Prompt) > workflowMaxConfig || len(c.Path) > 500 || len(c.Title) > 300 || len(n.ID) > 40 || len(c.Show) > workflowMaxNodes {
			return apperr.Invalid("graph", "node %q has a field that is too long", n.ID)
		}
	}
	return nil
}

func workflowParents(g WorkflowGraph) map[string][]string {
	p := make(map[string][]string, len(g.Nodes))
	for _, e := range g.Edges {
		p[e.To] = append(p[e.To], e.From)
	}
	return p
}

func workflowChildren(g WorkflowGraph) map[string][]string {
	c := make(map[string][]string, len(g.Nodes))
	for _, e := range g.Edges {
		c[e.From] = append(c[e.From], e.To)
	}
	return c
}

// walkWorkflow returns every node reachable from start through next, excluding start.
func walkWorkflow(next map[string][]string, start string) map[string]bool {
	seen := map[string]bool{}
	stack := slices.Clone(next[start])
	for len(stack) > 0 {
		id := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if !seen[id] {
			seen[id] = true
			stack = append(stack, next[id]...)
		}
	}
	return seen
}

// workflowOrder is a stable topological order (declared order breaks ties).
// ok is false when the edges among known nodes contain a cycle.
func workflowOrder(g WorkflowGraph) (order []WorkflowNode, ok bool) {
	known := make(map[string]bool, len(g.Nodes))
	for _, n := range g.Nodes {
		known[n.ID] = true
	}
	degree := map[string]int{}
	seen := map[WorkflowEdge]bool{}
	children := map[string][]string{}
	for _, e := range g.Edges {
		if known[e.From] && known[e.To] && !seen[e] {
			seen[e] = true
			degree[e.To]++
			children[e.From] = append(children[e.From], e.To)
		}
	}
	placed := make(map[string]bool, len(g.Nodes))
	for len(order) < len(g.Nodes) {
		progress := false
		for _, n := range g.Nodes {
			if !placed[n.ID] && degree[n.ID] == 0 {
				placed[n.ID] = true
				order = append(order, n)
				for _, c := range children[n.ID] {
					degree[c]--
				}
				progress = true
			}
		}
		if !progress {
			return order, false
		}
	}
	return order, true
}

// ValidateWorkflow lists everything that stops a graph being published.
func ValidateWorkflow(g WorkflowGraph) []WorkflowIssue {
	issues := []WorkflowIssue{}
	add := func(node, format string, args ...any) {
		issues = append(issues, WorkflowIssue{Node: node, Message: fmt.Sprintf(format, args...)})
	}
	if err := checkWorkflowBounds(g); err != nil {
		add("", "%s", err.Error())
		return issues
	}
	byID := make(map[string]WorkflowNode, len(g.Nodes))
	triggers := 0
	for _, n := range g.Nodes {
		if !workflowIDRe.MatchString(n.ID) {
			add(n.ID, "Node id %q must be lowercase letters, digits or underscores", n.ID)
		}
		if _, dup := byID[n.ID]; dup {
			add(n.ID, "Node id %q is used twice", n.ID)
		}
		byID[n.ID] = n
		if !slices.Contains(workflowNodeTypes, n.Type) {
			add(n.ID, "Unknown node type %q", n.Type)
		}
		if strings.TrimSpace(n.Title) == "" {
			add(n.ID, "Give this node a title")
		}
		if n.Type == NodeTrigger {
			triggers++
		}
	}
	if triggers != 1 {
		add("", "A workflow needs exactly one trigger")
	}
	if len(g.Nodes) < 2 {
		add("", "Add at least one step after the trigger")
	}
	seen := map[WorkflowEdge]bool{}
	for _, e := range g.Edges {
		from, okFrom := byID[e.From]
		to, okTo := byID[e.To]
		switch {
		case !okFrom || !okTo:
			add("", "A connection points at a node that doesn't exist (%s → %s)", e.From, e.To)
		case e.From == e.To:
			add(e.From, "A node can't connect to itself")
		case seen[e]:
			add(e.From, "Duplicate connection to %s", to.Title)
		case to.Type == NodeTrigger:
			add(e.To, "Nothing can run before the trigger")
		case slices.Contains(workflowOutputTypes, from.Type):
			add(e.From, "Outputs end a branch: nothing can follow them")
		}
		seen[e] = true
	}
	if _, ok := workflowOrder(g); !ok {
		add("", "The connections form a cycle. Use a gate's Request changes to loop back")
		return issues
	}
	parents, children := workflowParents(g), workflowChildren(g)
	for _, n := range g.Nodes {
		ancestors := walkWorkflow(parents, n.ID)
		if n.Type != NodeTrigger && len(parents[n.ID]) == 0 {
			add(n.ID, "Connect something into this node")
		}
		if n.Type != NodeTrigger && !slices.Contains(workflowOutputTypes, n.Type) && len(children[n.ID]) == 0 {
			add(n.ID, "Connect this node to a next step or an output")
		}
		c := n.Config
		if c.Check && n.Type != NodeAgent {
			add(n.ID, "Only agent steps can be checks")
		}
		if c.RequiresCheck != "" && n.Type != NodeGate {
			add(n.ID, "Only gates can be tied to a check")
		}
		retryable := func(id string) bool {
			target, known := byID[id]
			return known && ancestors[id] && (target.Type == NodeEnrich || target.Type == NodeAgent)
		}
		switch n.Type {
		case NodeAgent:
			if strings.TrimSpace(c.Prompt) == "" {
				add(n.ID, "Say what this step should do")
			}
			if c.PersonaID != "" && c.AgentHandle != "" {
				add(n.ID, "Choose a persona or an agent, not both")
			}
			if c.Images && c.AgentHandle != "" {
				add(n.ID, "Image steps run as a persona: remove the agent handle")
			}
			if c.ImageEngine != "" && !ValidImageEngine(c.ImageEngine) {
				add(n.ID, "Image engine must be auto, codex or antigravity")
			}
			if c.Check {
				if c.Images {
					add(n.ID, "A check can't also generate images: check them in a step after this one")
				}
				if c.RetryFrom != "" && !retryable(c.RetryFrom) {
					add(n.ID, "A failed check must re-run an enrich or agent step before it")
				}
				if c.MaxAttempts < 0 || c.MaxAttempts > workflowMaxAttempts {
					add(n.ID, "Attempts must be between 1 and %d", workflowMaxAttempts)
				}
			}
		case NodeGate:
			if c.RetryFrom != "" && !retryable(c.RetryFrom) {
				add(n.ID, "Request changes must re-run an enrich or agent step before this gate")
			}
			if c.MaxAttempts < 0 || c.MaxAttempts > workflowMaxAttempts {
				add(n.ID, "Reviews must be between 1 and %d", workflowMaxAttempts)
			}
			if c.RequiresCheck != "" {
				check, known := byID[c.RequiresCheck]
				switch {
				case !known || check.Type != NodeAgent || !check.Config.Check || !slices.Contains(parents[n.ID], c.RequiresCheck):
					add(n.ID, "This gate must be tied to a check connected directly into it")
				case c.RetryFrom != "" && c.RetryFrom != c.RequiresCheck && !walkWorkflow(children, c.RetryFrom)[c.RequiresCheck]:
					add(n.ID, "Request changes must re-run %s, or Approve could never unlock", check.Title)
				}
			}
			for _, id := range c.Show {
				if !ancestors[id] {
					add(n.ID, "This gate shows %q, which doesn't run before it", id)
				}
			}
		case NodeWiki:
			if strings.TrimSpace(c.Path) == "" {
				add(n.ID, "Give the wiki page a path")
			}
			if c.Mode != "" && c.Mode != "replace" && c.Mode != "append" {
				add(n.ID, "Wiki mode must be replace or append")
			}
			if !slices.ContainsFunc(g.Nodes, func(o WorkflowNode) bool { return o.Type == NodeGate && ancestors[o.ID] }) {
				add(n.ID, "Wiki writes need a human gate before them")
			}
		case NodeLibrary, NodeTicket:
			if strings.TrimSpace(c.Title) == "" {
				add(n.ID, "Give the item a title")
			}
		}
		for _, field := range []string{c.Prompt, c.Path, c.Title} {
			for _, m := range workflowVarRe.FindAllStringSubmatch(field, -1) {
				if m[1] != "input" && !ancestors[m[1]] {
					add(n.ID, "{{%s}} doesn't run before this node", m[1])
				}
			}
		}
	}
	return issues
}

// ApplyWorkflowOps returns the graph after a persona's edits. New nodes
// without a position are laid out by depth.
func ApplyWorkflowOps(g WorkflowGraph, ops []WorkflowOp) (WorkflowGraph, error) {
	out := WorkflowGraph{Nodes: slices.Clone(g.Nodes), Edges: slices.Clone(g.Edges)}
	find := func(id string) int {
		return slices.IndexFunc(out.Nodes, func(n WorkflowNode) bool { return n.ID == id })
	}
	for i, op := range ops {
		switch op.Op {
		case "add_node":
			if op.Node == nil {
				return out, apperr.Invalid("ops", "op %d: add_node needs a node", i)
			}
			if find(op.Node.ID) >= 0 {
				return out, apperr.Invalid("ops", "op %d: node %q already exists", i, op.Node.ID)
			}
			out.Nodes = append(out.Nodes, *op.Node)
		case "update_node":
			if op.Node == nil {
				return out, apperr.Invalid("ops", "op %d: update_node needs a node", i)
			}
			at := find(op.Node.ID)
			if at < 0 {
				return out, apperr.Invalid("ops", "op %d: no node %q", i, op.Node.ID)
			}
			next := *op.Node
			next.X, next.Y = out.Nodes[at].X, out.Nodes[at].Y
			out.Nodes[at] = next
		case "remove_node":
			at := find(op.NodeID)
			if at < 0 {
				return out, apperr.Invalid("ops", "op %d: no node %q", i, op.NodeID)
			}
			out.Nodes = slices.Delete(out.Nodes, at, at+1)
			out.Edges = slices.DeleteFunc(out.Edges, func(e WorkflowEdge) bool { return e.From == op.NodeID || e.To == op.NodeID })
		case "add_edge":
			e := WorkflowEdge{From: op.From, To: op.To}
			if !slices.Contains(out.Edges, e) {
				out.Edges = append(out.Edges, e)
			}
		case "remove_edge":
			e := WorkflowEdge{From: op.From, To: op.To}
			at := slices.Index(out.Edges, e)
			if at < 0 {
				return out, apperr.Invalid("ops", "op %d: no connection %s → %s", i, op.From, op.To)
			}
			out.Edges = slices.Delete(out.Edges, at, at+1)
		default:
			return out, apperr.Invalid("ops", "op %d: unknown op %q", i, op.Op)
		}
	}
	layoutNewWorkflowNodes(&out)
	return out, nil
}

func layoutNewWorkflowNodes(g *WorkflowGraph) {
	order, ok := workflowOrder(*g)
	if !ok {
		return
	}
	depth := map[string]int{}
	parents := workflowParents(*g)
	rows := map[int]int{}
	positions := map[string][2]float64{}
	for _, n := range order {
		for _, p := range parents[n.ID] {
			depth[n.ID] = max(depth[n.ID], depth[p]+1)
		}
		if n.X == 0 && n.Y == 0 {
			positions[n.ID] = [2]float64{40 + float64(depth[n.ID])*240, 200 + float64(rows[depth[n.ID]])*130}
		}
		rows[depth[n.ID]]++
	}
	for i := range g.Nodes {
		if p, moved := positions[g.Nodes[i].ID]; moved {
			g.Nodes[i].X, g.Nodes[i].Y = p[0], p[1]
		}
	}
}

// renderWorkflowTemplate fills {{input}} and {{node.output}}.
func renderWorkflowTemplate(t string, vars map[string]string) string {
	return workflowVarRe.ReplaceAllStringFunc(t, func(m string) string {
		return vars[workflowVarRe.FindStringSubmatch(m)[1]]
	})
}

type workflowStepView struct {
	State string
	Check string
}

// workflowReady lists the nodes to start now, in order: their newest attempt
// is missing or stale, and every parent's newest attempt is done. A check
// that hasn't passed holds back everything but a gate tied to it.
func workflowReady(g WorkflowGraph, latest map[string]workflowStepView) []WorkflowNode {
	order, ok := workflowOrder(g)
	if !ok {
		return nil
	}
	parents := workflowParents(g)
	checks := map[string]bool{}
	for _, n := range g.Nodes {
		checks[n.ID] = n.Type == NodeAgent && n.Config.Check
	}
	var ready []WorkflowNode
	for _, n := range order {
		if s, started := latest[n.ID]; started && s.State != "stale" {
			continue
		}
		tied := func(p string) bool { return n.Type == NodeGate && n.Config.RequiresCheck == p }
		if !slices.ContainsFunc(parents[n.ID], func(p string) bool {
			return latest[p].State != "done" || (checks[p] && latest[p].Check != workflowCheckPassed && !tied(p))
		}) {
			ready = append(ready, n)
		}
	}
	return ready
}
