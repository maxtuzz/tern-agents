-- Unit and load tests, runnable without Tern:
--   tests/run.sh      (bundles every module, then runs this)
-- Exits non-zero when anything fails.

local stub = require("./stub")

local util = require("../lib/util")
local catalog = require("../lib/catalog")
local cfg = require("../lib/config")
local command = require("../lib/command")
local quick = require("../lib/quick")
local status = require("../lib/status")
local forms = require("../lib/forms")
local orca = require("../lib/orca")
local runs = require("../lib/runs")
local model = require("../lib/model")
local detect = require("../lib/detect")
local launch = require("../lib/launch")
local url = require("../lib/url")
local field = require("../lib/field")

local passed, failed = 0, 0

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		print("FAIL " .. name .. ": " .. tostring(err))
	end
end

local function eq(a: any, b: any, what: string?)
	if a ~= b then
		error(string.format("%s: expected %s, got %s", what or "value", tostring(b), tostring(a)), 2)
	end
end

local function truthy(value: any, what: string?)
	if not value then
		error((what or "value") .. ": expected something truthy", 2)
	end
end

local function has(haystack: string, needle: string)
	if not string.find(haystack, needle, 1, true) then
		error("missing " .. needle .. " in " .. haystack, 2)
	end
end

local function lacks(haystack: string, needle: string)
	if string.find(haystack, needle, 1, true) then
		error("unexpected " .. needle .. " in " .. haystack, 2)
	end
end

local function raises(fn: () -> (), needle: string)
	local ok, err = pcall(fn)
	if ok then
		error("expected an error containing " .. needle, 2)
	end
	if not string.find(tostring(err), needle, 1, true) then
		error("error " .. tostring(err) .. " lacks " .. needle, 2)
	end
end

-- util ---------------------------------------------------------------------

test("split_args splits a shell line and consumes its quotes", function()
	local words = util.split_args("claude --model opus")
	eq(#words, 3)
	eq(words[2], "--model")
	local quoted = util.split_args("codex -c model_reasoning_effort=\"high\" --sandbox danger-full-access")
	eq(#quoted, 5)
	eq(quoted[2], "-c")
	eq(quoted[3], "model_reasoning_effort=high")
	local single = util.split_args("agent --say 'hello world' end")
	eq(#single, 4)
	eq(single[3], "hello world")
	eq(#util.split_args("   "), 0)
	eq(util.split_args("a\\ b")[1], "a b")
end)

test("shell_quote leaves plain words alone and quotes the rest", function()
	eq(util.shell_quote("claude"), "claude")
	eq(util.shell_quote("--model=opus"), "--model=opus")
	eq(util.shell_quote("fix the build"), "'fix the build'")
	eq(util.shell_quote("it's"), "'it'\\''s'")
	eq(util.shell_quote("$HOME"), "'$HOME'")
	eq(util.shell_quote(""), "''")
end)

test("dquote_escape protects a double-quoted shell string", function()
	eq(util.dquote_escape("exec claude"), "exec claude")
	eq(util.dquote_escape('say "hi"'), 'say \\"hi\\"')
	eq(util.dquote_escape("cost $5 `now`"), "cost \\$5 \\`now\\`")
	eq(util.dquote_escape("back\\slash"), "back\\\\slash")
end)

test("join_args round-trips a line through quoting", function()
	eq(util.join_args({ "claude", "--model", "opus" }), "claude --model opus")
	eq(util.join_args({ "claude", "fix the build" }), "claude 'fix the build'")
end)

test("string_list and env_map take either shape", function()
	eq(#util.string_list("--a --b"), 2)
	eq(#util.string_list({ "--a", 7, "--b" }), 2)
	eq(#util.string_list(nil), 0)
	local env = util.env_map({ GOOSE_MODE = "auto", bad_key = true, ["1nope"] = "x" })
	eq(env.GOOSE_MODE, "auto")
	eq(env.bad_key, "true")
	eq(env["1nope"], nil)
end)

test("age, slug, clip and tilde read like labels", function()
	eq(util.age(3), "just now")
	eq(util.age(180), "3m")
	eq(util.age(7200), "2h")
	eq(util.age(172800), "2d")
	eq(util.slug("Yolo Mode!"), "yolo-mode")
	eq(util.clip("abcdefg", 4), "abc…")
	eq(util.tilde("/Users/me/dev", "/Users/me"), "~/dev")
	eq(util.resolve("/r", "~/dev", "/Users/me"), "/Users/me/dev")
	truthy(util.inside("/a/b", "/a"))
end)

-- config -------------------------------------------------------------------

local function config_with(kv_layer: any, file_layer: any): cfg.Config
	return cfg.build(kv_layer, file_layer)
end

test("the built-in catalog ships Max's claude preset", function()
	local config = cfg.defaults()
	local preset = cfg.find_preset(config, "claude", "yolo")
	truthy(preset, "claude yolo")
	eq((preset :: cfg.Preset).args[1], "--dangerously-skip-permissions")
	eq(config.agents.claude.prompt_arg, "positional")
	eq(config.agents.claude.title_status, "claude")
	eq(config.agents["cursor-agent"].bin, "cursor-agent")
	truthy(config.agents.claude.verified, "claude is verified")
	truthy(not config.agents.gemini.verified, "gemini is unverified")
	eq(#catalog.order() > 10, true)
end)

test("the kv layer overrides built-ins and adds presets", function()
	local config = config_with({
		agents = { claude = { label = "Claude", args = "--verbose" } },
		presets = { ["claude:tiny"] = { agent = "claude", name = "tiny", args = "--model haiku" } },
		default_presets = { claude = "claude:tiny" },
	}, nil)
	eq(config.agents.claude.label, "Claude")
	eq(config.agents.claude.args[1], "--verbose")
	eq(config.agents.claude.bin, "claude", "an override keeps what it doesn't mention")
	eq(config.agents.claude.source, "kv")
	local tiny = cfg.find_preset(config, "claude", "tiny")
	truthy(tiny)
	eq((cfg.default_preset_of(config, "claude") :: cfg.Preset).id, "claude:tiny")
end)

test("agents.json wins over the kv layer", function()
	local config = config_with(
		{ agents = { claude = { bin = "/kv/claude" } }, presets = { ["claude:yolo"] = { args = "--kv" } } },
		{ agents = { claude = { bin = "/hand/claude" } }, presets = { ["claude:yolo"] = { args = "--hand" } } }
	)
	eq(config.agents.claude.bin, "/hand/claude")
	eq(config.agents.claude.source, cfg.FILE)
	eq((cfg.find_preset(config, "claude", "yolo") :: cfg.Preset).args[1], "--hand")
	eq((cfg.find_preset(config, "claude", "yolo") :: cfg.Preset).source, cfg.FILE)
end)

test("a malformed layer is reported and ignored", function()
	local config = config_with("not an object", nil)
	eq(#config.problems, 1)
	has(config.problems[1], "must hold a JSON object")
	truthy(config.agents.claude, "the built-ins survive")
	local broken = config_with({ agents = { ["bad id"] = { bin = "x" } }, presets = { ["nope"] = 7 } }, nil)
	eq(#broken.problems, 2)
	has(broken.problems[1], "agent")
	truthy(broken.agents.claude, "one bad entry doesn't take the rest")
end)

test("remove_presets hides a built-in preset", function()
	local config = config_with({ remove_presets = { "claude:haiku" } }, nil)
	eq(cfg.find_preset(config, "claude", "haiku"), nil)
	truthy(cfg.find_preset(config, "claude", "yolo"))
end)

test("agents and presets are found by id, name, label or binary", function()
	local config = cfg.defaults()
	eq((cfg.find_agent(config, "CLAUDE") :: cfg.Agent).id, "claude")
	eq((cfg.find_agent(config, "Claude Code") :: cfg.Agent).id, "claude")
	eq((cfg.find_agent(config, "cursor-agent") :: cfg.Agent).id, "cursor-agent")
	eq(cfg.find_agent(config, "nope"), nil)
	eq((cfg.find_preset(config, "claude", "claude:opus") :: cfg.Preset).name, "opus")
	eq(cfg.find_preset(config, "codex", "opus"), nil, "a preset belongs to one agent")
end)

test("an agent's presets list its plain one first", function()
	local list = cfg.presets_of(cfg.defaults(), "claude")
	eq(list[1].name, "claude")
	eq(list[2].name, "haiku")
end)

test("default preset resolution walks per-agent, then global, then plain", function()
	local plain = cfg.defaults()
	eq((cfg.default_preset_of(plain, "claude") :: cfg.Preset).id, "claude:claude")
	local global = config_with({ default_preset = "claude:yolo" }, nil)
	eq((cfg.default_preset_of(global, "claude") :: cfg.Preset).id, "claude:yolo")
	eq((cfg.default_preset_of(global, "codex") :: cfg.Preset).id, "codex:codex", "another agent keeps its own")
	local per_agent = config_with({ default_preset = "claude:yolo", default_presets = { claude = "claude:opus" } }, nil)
	eq((cfg.default_preset_of(per_agent, "claude") :: cfg.Preset).id, "claude:opus")
end)

test("resolve picks the pair a launch should use", function()
	local config = config_with({ default_agent = "codex" }, nil)
	local agent, preset = cfg.resolve(config, "claude", "yolo", nil)
	eq(agent.id, "claude")
	eq(preset.id, "claude:yolo")
	local default_agent = cfg.resolve(config, nil, nil, nil)
	eq(default_agent.id, "codex", "the default agent is used when none is named")
	raises(function()
		cfg.resolve(config, "nope", nil, nil)
	end, "No agent")
	raises(function()
		cfg.resolve(config, "claude", "nope", nil)
	end, "No preset")
	local bare = cfg.defaults()
	raises(function()
		cfg.resolve(bare, nil, nil, {})
	end, "No default agent")
	local only = cfg.resolve(bare, nil, nil, { opencode = true })
	eq(only.id, "opencode", "one detected agent needs no default")
end)

test("the agent list follows what was detected, and the file", function()
	local config = config_with(nil, { agents = { mycli = { bin = "mycli", label = "My CLI" } } })
	local shown: { [string]: boolean } = {}
	for _, agent in cfg.agent_list(config, { claude = true, codex = true }) do
		shown[agent.id] = true
	end
	truthy(shown.claude)
	truthy(shown.codex)
	truthy(shown.mycli, "an agent named in agents.json is always offered")
	eq(shown.gemini, nil, "an undetected built-in is not")
	local all = cfg.agent_list(config, nil)
	eq(#all >= 14, true, "no detection means everything")
	eq(all[1].id, "claude", "catalog order first")
end)

test("hidden agents stay out of the list", function()
	local config = config_with({ agents = { codex = { hidden = true } } }, nil)
	for _, agent in cfg.agent_list(config, { claude = true, codex = true }) do
		truthy(agent.id ~= "codex", "codex is hidden")
	end
end)

-- command ------------------------------------------------------------------

local function build(config: cfg.Config, agent_id: string, preset_name: string, opts: command.Options?): command.Spec
	local agent = cfg.find_agent(config, agent_id) :: cfg.Agent
	local preset = cfg.find_preset(config, agent_id, preset_name) :: cfg.Preset
	local o: command.Options = opts or {}
	o.shell = if o.shell == nil then config.shell else o.shell
	o.delivery = o.delivery or config.prompt_delivery
	return command.build(agent, preset, o)
end

test("a built line runs through the user's login shell", function()
	local spec = build(cfg.defaults(), "claude", "yolo", { shell_path = "/bin/zsh" })
	eq(spec.inner, "claude --dangerously-skip-permissions")
	eq(spec.line, '/bin/zsh -lic "exec claude --dangerously-skip-permissions"')
	truthy(spec.shell)
	eq(spec.program, "claude")
end)

test("shell = false runs the command as it is", function()
	local config = config_with({ shell = false }, nil)
	local spec = build(config, "claude", "yolo")
	eq(spec.line, "claude --dangerously-skip-permissions")
	truthy(not spec.shell)
	local per_agent = config_with({ agents = { claude = { shell = false } } }, nil)
	truthy(not build(per_agent, "claude", "yolo").shell, "an agent can opt out on its own")
	local per_preset = config_with({ presets = { ["claude:yolo"] = { shell = false } } }, nil)
	truthy(not build(per_preset, "claude", "yolo").shell, "so can a preset")
end)

test("preset args are appended, and replace_args drops the agent's own", function()
	local appended = config_with({ agents = { claude = { args = "--verbose" } } }, nil)
	eq(build(appended, "claude", "yolo").inner, "claude --verbose --dangerously-skip-permissions")
	local replaced = config_with({
		agents = { claude = { args = "--verbose" } },
		presets = { ["claude:yolo"] = { replace_args = true } },
	}, nil)
	eq(build(replaced, "claude", "yolo").inner, "claude --dangerously-skip-permissions")
end)

test("a whole command line is honored and re-quoted faithfully", function()
	local config = config_with({
		presets = {
			["codex:orca"] = {
				agent = "codex",
				name = "orca",
				command = 'codex -c model_reasoning_effort="high" --ask-for-approval never --sandbox danger-full-access',
			},
		},
	}, nil)
	local spec = build(config, "codex", "orca")
	has(spec.inner, "model_reasoning_effort=high")
	has(spec.line, '/bin/zsh -lic "exec codex -c model_reasoning_effort=high')
	eq(spec.program, "codex")
end)

test("env variables become an env prefix, sorted and quoted", function()
	local config = config_with({
		agents = { goose = { env = { GOOSE_MODE = "auto", A_VAR = "two words" } } },
	}, nil)
	local spec = build(config, "goose", "goose")
	eq(spec.inner, "env 'A_VAR=two words' GOOSE_MODE=auto goose")
	eq(spec.env.GOOSE_MODE, "auto")
end)

test("a prompt is delivered by Tern unless the agent takes it on the command line", function()
	local config = cfg.defaults()
	local typed = build(config, "claude", "yolo", { prompt = "fix the build" })
	eq(typed.delivery, "block")
	truthy(not typed.prompt_on_argv)
	lacks(typed.inner, "fix the build")

	local positional = build(config, "claude", "yolo", { prompt = "fix the build", delivery = "argv" })
	eq(positional.delivery, "argv")
	truthy(positional.prompt_on_argv)
	eq(positional.inner, "claude --dangerously-skip-permissions 'fix the build'")

	local flagged = build(config, "opencode", "yolo", { prompt = "fix it", delivery = "argv" })
	eq(flagged.inner, "opencode --auto --prompt 'fix it'")

	local unsupported = build(config, "aider", "yolo", { prompt = "fix it", delivery = "argv" })
	eq(unsupported.delivery, "block", "an agent with no prompt argument falls back")
	truthy(unsupported.note)
	has(unsupported.note :: string, "typed in")

	local no_prompt = build(config, "claude", "yolo", { delivery = "argv" })
	eq(no_prompt.delivery, "block", "nothing to put on the line")
end)

test("a prompt full of shell metacharacters survives both layers", function()
	local spec = build(cfg.defaults(), "claude", "claude", {
		prompt = 'fix $PATH and "quotes" `now`',
		delivery = "argv",
		shell_path = "/bin/zsh",
	})
	eq(spec.argv[2], 'fix $PATH and "quotes" `now`')
	has(spec.line, "\\$PATH")
	has(spec.line, '\\"quotes\\"')
	has(spec.line, "\\`now\\`")
end)

test("a profile with no program is refused", function()
	local agent: cfg.Agent = {
		id = "broken",
		label = "Broken",
		bin = "",
		args = {},
		env = {},
		icon = "sparkle",
		prompt_arg = "none",
		title_status = "none",
		verified = false,
		source = "kv",
	}
	local preset: cfg.Preset = { id = "broken:broken", name = "broken", agent = "broken", args = {}, source = "kv" }
	raises(function()
		command.build(agent, preset, {})
	end, "has no command to run")
	local blank_line = table.clone(preset)
	blank_line.command = "   "
	raises(function()
		command.build(agent, blank_line, {})
	end, "has no command to run")
end)

test("a launch label names the agent, and the preset when it adds something", function()
	local config = cfg.defaults()
	local claude = cfg.find_agent(config, "claude") :: cfg.Agent
	eq(command.label(claude, cfg.find_preset(config, "claude", "claude") :: cfg.Preset), "Claude Code")
	eq(command.label(claude, cfg.find_preset(config, "claude", "yolo") :: cfg.Preset), "Claude Code · yolo")
end)

-- quick entry --------------------------------------------------------------

local function lookup(default_agent: string?): quick.Lookup
	local config = cfg.defaults()
	return {
		agent = function(token: string): string?
			local agent = cfg.find_agent(config, token)
			return if agent then agent.id else nil
		end,
		preset = function(agent: string, token: string): string?
			local preset = cfg.find_preset(config, agent, token)
			return if preset then preset.id else nil
		end,
		default_agent = function(): string?
			return default_agent
		end,
	}
end

test("quick entry reads agent, preset and prompt", function()
	local parsed = quick.parse("claude yolo fix the build", lookup(nil))
	eq(parsed.agent, "claude")
	eq(parsed.preset, "claude:yolo")
	eq(parsed.prompt, "fix the build")
end)

test("quick entry leaves a prompt that starts with an ordinary word alone", function()
	local parsed = quick.parse("claude fix the build", lookup(nil))
	eq(parsed.agent, "claude")
	eq(parsed.preset, nil)
	eq(parsed.prompt, "fix the build")
	local bare = quick.parse("fix the build", lookup(nil))
	eq(bare.agent, nil)
	eq(bare.prompt, "fix the build")
end)

test("quick entry takes a preset of the default agent first", function()
	local parsed = quick.parse("yolo fix it", lookup("claude"))
	eq(parsed.agent, "claude")
	eq(parsed.preset, "claude:yolo")
	eq(parsed.prompt, "fix it")
	eq(quick.parse("yolo fix it", lookup(nil)).prompt, "yolo fix it", "with no default it is a prompt")
end)

test("quick entry accepts a colon after the agent or preset", function()
	local parsed = quick.parse("opus: explain this", lookup("claude"))
	eq(parsed.agent, "claude")
	eq(parsed.preset, "claude:opus")
	eq(parsed.prompt, "explain this")
	local agent_colon = quick.parse("codex: look around", lookup(nil))
	eq(agent_colon.agent, "codex")
	eq(agent_colon.prompt, "look around")
	local bad = quick.parse("nope: do it", lookup("claude"))
	truthy(bad.problem)
	has(bad.problem :: string, "No agent or preset")
end)

test("quick entry takes a directory with @ and keeps it out of the prompt", function()
	local parsed = quick.parse("claude yolo @~/dev/app read the diff", lookup(nil))
	eq(parsed.cwd, "~/dev/app")
	eq(parsed.prompt, "read the diff")
	local trailing = quick.parse("claude read the diff @/tmp/x", lookup(nil))
	eq(trailing.cwd, "/tmp/x")
	eq(trailing.prompt, "read the diff")
	eq(quick.parse("@ x", lookup(nil)).problem, nil, "a bare @ is just a word")
end)

test("an agent alone launches with no prompt", function()
	local parsed = quick.parse("codex", lookup(nil))
	eq(parsed.agent, "codex")
	eq(parsed.prompt, nil)
	eq(quick.parse("   ", lookup(nil)).agent, nil)
end)

-- status -------------------------------------------------------------------

test("Claude's title says idle or working", function()
	eq(status.from_title("✳ Reviewing the diff", "claude"), "idle")
	eq(status.from_title("◐ Thinking…", "claude"), "working")
	eq(status.from_title("⠹ Running tests", "claude"), "working")
	eq(status.from_title("claude", "claude"), nil)
	eq(status.from_title("", "claude"), nil)
end)

test("the spinner heuristic is all another TUI gives", function()
	eq(status.from_title("⠙ building", "spinner"), "working")
	eq(status.from_title("codex", "spinner"), nil)
	eq(status.from_title("✳ idle", "none"), nil, "no heuristic claims nothing")
end)

test("a status is read from the exit code, the title, then busy", function()
	eq(status.of(nil, "claude").state, "closed")
	local ok = status.of({ exited = 0 }, "claude")
	eq(ok.state, "exited")
	eq(ok.label, "exited")
	local bad = status.of({ exited = 1 }, "claude")
	eq(bad.label, "exit 1")
	eq(bad.tone, "error")
	eq(status.of({ title = "✳ done" }, "claude").state, "idle")
	eq(status.of({ title = "◑ x" }, "claude").state, "working")
	eq(status.of({ title = "plain", busy = true }, "claude").state, "working")
	eq(status.of({ title = "plain" }, "claude").state, "running")
	eq(status.of({ title = "✳ done", exited = 0 }, "claude").state, "exited", "an exit wins")
	truthy(status.alive("idle"))
	truthy(not status.alive("exited"))
end)

-- the editing grammars -----------------------------------------------------

test("Add preset… reads an agent, a name and its args", function()
	local known = function(token: string): boolean
		return token == "claude"
	end
	local parsed = forms.parse_preset("claude yolo --dangerously-skip-permissions", known)
	eq(parsed.agent, "claude")
	eq(parsed.name, "yolo")
	eq(parsed.args[1], "--dangerously-skip-permissions")
	eq(#forms.parse_preset("claude plain", known).args, 0)
	has(forms.parse_preset("nope x", known).problem :: string, "No agent")
	has(forms.parse_preset("claude", known).problem :: string, "Type a name")
	has(forms.parse_preset("claude in", known).problem :: string, "quick-entry keyword")
	eq(forms.parse_preset("claude opus  --model   opus", known).args[2], "opus")
end)

test("Add agent… reads an id, a binary and its args", function()
	local parsed = forms.parse_agent("mycli /opt/bin/mycli --quiet")
	eq(parsed.id, "mycli")
	eq(parsed.bin, "/opt/bin/mycli")
	eq(parsed.args[1], "--quiet")
	eq(forms.parse_agent("mycli").bin, "mycli", "the binary defaults to the id")
	has(forms.parse_agent("-bad").problem :: string, "starts with a letter")
	eq(forms.parse_agent("").id, nil)
end)

-- importing from Orca ------------------------------------------------------

test("Orca's agent settings become profiles and presets", function()
	local layer = orca.layer({
		settings = {
			defaultTuiAgent = "omp",
			disabledTuiAgents = { "claude-agent-teams", "amp" },
			agentCmdOverrides = {
				claude = "claude --dangerously-skip-permissions",
				codex = 'codex -c model_reasoning_effort="high" --ask-for-approval never',
			},
			agentDefaultArgs = { gemini = "--yolo", cursor = "--yolo", claude = "" },
			agentDefaultEnv = { goose = { GOOSE_MODE = "auto" } },
			terminalQuickCommands = {
				{ action = "agent-prompt", agent = "claude", label = "Run PR toolkit", prompt = "Review this branch" },
				{ action = "terminal-command", command = "lazygit", label = "Lazygit" },
			},
		},
	})
	eq(layer.default_agent, "omp")
	eq(layer.presets["claude:orca"].command, "claude --dangerously-skip-permissions")
	has(layer.presets["codex:orca"].command, "model_reasoning_effort")
	eq(layer.presets["gemini:yolo"].args, "--yolo")
	eq(layer.presets["cursor-agent:yolo"].args, "--yolo", "cursor is our cursor-agent")
	eq(layer.presets["claude:yolo"], nil, "an empty arg string is not a preset")
	eq(layer.agents.goose.env.GOOSE_MODE, "auto")
	eq(layer.presets["claude:run-pr-toolkit"].prompt, "Review this branch")
	eq(layer.agents.amp.hidden, true)
	eq(layer.agents.claude.hidden, nil, "claude-agent-teams doesn't hide claude")
end)

test("the Orca layer applies on top of the built-ins", function()
	local layer = orca.layer({ settings = { agentCmdOverrides = { claude = "claude --dangerously-skip-permissions" } } })
	local config = cfg.build(layer, nil)
	local preset = cfg.find_preset(config, "claude", "orca") :: cfg.Preset
	truthy(preset)
	eq(build(config, "claude", "orca").inner, "claude --dangerously-skip-permissions")
end)

test("a missing or odd Orca file is simply empty", function()
	eq(next(orca.layer(nil)), nil)
	eq(next(orca.layer("nope")), nil)
	eq(next(orca.layer({ settings = { agentCmdOverrides = "not a table" } })), nil)
	has(orca.path("/Users/me"), "/Users/me/Library/Application Support/Orca/orca-data.json")
	local layer, problem = orca.read("/nothing/here.json")
	eq(next(layer), nil)
	eq(problem, nil, "an absent file is not a problem")
end)

-- launch records -----------------------------------------------------------

local function record(pane: number, started: number): runs.Record
	return {
		pane = pane,
		agent = "claude",
		preset = "claude:yolo",
		label = "Claude Code · yolo",
		cwd = "/r",
		command = "claude",
		started_at = started,
		kind = "block",
		title_status = "claude",
	}
end

test("launch records are stored, patched, listed newest first and pruned", function()
	stub.reset()
	local now = os.time()
	runs.put(record(11, now - 100))
	runs.put(record(12, now - 10))
	local list = runs.list()
	eq(#list, 2)
	eq(list[1].pane, 12, "newest first")
	runs.patch(11, { exited = 2 })
	eq((runs.get(11) :: runs.Record).exited, 2)
	eq(runs.stale({ [11] = record(11, now - 100), [12] = record(12, now) }, { [12] = true }, now)[1], 11)
	eq(#runs.stale({ [12] = record(12, now) }, {}, now), 0, "a young record waits for its pane")
	eq(runs.prune({ [12] = true }), 1)
	eq(runs.get(11), nil)
	runs.drop(12)
	eq(#runs.list(), 0)
	stub.reset()
end)

test("rows join the records with what the panes say", function()
	local now = os.time()
	local rows = model.rows({ record(11, now - 60), record(12, now - 5) }, {
		[11] = { title = "◐ working" },
	}, now)
	eq(#rows, 2)
	eq(rows[1].status.state, "working")
	eq(rows[1].age, 60)
	eq(rows[2].status.state, "closed", "a pane that isn't listed is gone")
	local counts = model.counts(rows)
	eq(counts.total, 2)
	eq(counts.working, 1)
	eq(counts.gone, 1)
	eq(model.element_status(rows[1]), "running")
	local failed_row = model.rows({ record(13, now) }, { [13] = { exited = 3 } }, now)[1]
	eq(model.element_status(failed_row), "failed")
	eq(model.element_status(model.rows({ record(14, now) }, { [14] = { exited = 0 } }, now)[1]), "done")
end)

-- detection ----------------------------------------------------------------

test("detection asks the login shell once for every candidate", function()
	local candidates = detect.candidates({
		claude = { bin = "claude" },
		mycli = { bin = "mycli", command = "/opt/bin/other --flag" },
	})
	eq(#candidates, 2)
	eq(candidates[1].id, "claude")
	eq(candidates[2].bin, "/opt/bin/other", "a command line's program is what we look for")
	local script = detect.script(candidates)
	has(script, "command -v -- claude")
	has(script, "command -v -- /opt/bin/other")
	has(script, "printf")
	local found = detect.parse("claude\t/usr/local/bin/claude\nnoise\ncodex\t/nvm/codex\n")
	eq(found.claude, "/usr/local/bin/claude")
	eq(found.codex, "/nvm/codex")
	eq(found.noise, nil)
end)

test("a probe caches its answer and goes stale with the shell", function()
	stub.reset()
	local cx = stub.window_cx()
	detect.refresh({ { id = "claude", bin = "claude" } }, nil)
	local argv = stub.answer(cx, 0, "claude\t/usr/local/bin/claude\n")
	eq(argv[1], "/bin/zsh")
	eq(argv[2], "-lic")
	local cache = detect.cached() :: detect.Cache
	eq(cache.found.claude, "/usr/local/bin/claude")
	eq(detect.map(cache).claude, true)
	truthy(not detect.stale(cache))
	truthy(detect.stale({ found = {}, at = os.time(), shell = "/bin/fish" }), "another shell is another PATH")
	truthy(detect.stale(nil))
	stub.reset()
end)

-- launching ----------------------------------------------------------------

test("a launch with a prompt opens a real agent block", function()
	stub.reset()
	local cx = stub.window_cx("/work/app")
	local config = cfg.defaults()
	local result = launch.run(cx, config, {
		agent = cfg.find_agent(config, "claude") :: cfg.Agent,
		preset = cfg.find_preset(config, "claude", "yolo") :: cfg.Preset,
		prompt = "Reply PONG",
	})
	eq(#cx.started, 1)
	local opts = cx.started[1].opts
	eq(opts.prompt, "Reply PONG")
	eq(opts.cwd, "/work/app", "the focused pane's directory")
	has(opts.command, '-lic "exec claude --dangerously-skip-permissions"')
	eq(opts.how, "split")
	eq(result.record.kind, "block")
	eq((runs.get(result.pane) :: runs.Record).preset, "claude:yolo")
	eq(#cx.launched, 0, "no terminal pane was needed")
	stub.reset()
end)

test("a launch without a prompt opens a terminal pane instead", function()
	stub.reset()
	local cx = stub.window_cx("/work/app")
	local config = cfg.defaults()
	local result = launch.run(cx, config, {
		agent = cfg.find_agent(config, "codex") :: cfg.Agent,
		preset = cfg.find_preset(config, "codex", "yolo") :: cfg.Preset,
	})
	eq(#cx.started, 0, "agents:start needs a prompt")
	eq(#cx.launched, 1)
	eq(cx.launched[1].kind, "split")
	has(cx.launched[1].launch.command, "--dangerously-bypass-approvals-and-sandbox")
	eq(result.record.kind, "pane")
	stub.reset()
end)

test("an argv-delivered prompt also opens a terminal pane, once", function()
	stub.reset()
	local cx = stub.window_cx("/work/app")
	local config = cfg.build({ prompt_delivery = "argv" }, nil)
	launch.run(cx, config, {
		agent = cfg.find_agent(config, "claude") :: cfg.Agent,
		preset = cfg.find_preset(config, "claude", "claude") :: cfg.Preset,
		prompt = "Reply PONG",
	})
	eq(#cx.started, 0)
	eq(#cx.launched, 1)
	has(cx.launched[1].launch.command, "'Reply PONG'")
	stub.reset()
end)

test("a preset's own directory, placement and prompt are used", function()
	stub.reset()
	local cx = stub.window_cx("/work/app")
	local config = cfg.build({
		presets = {
			["claude:review"] = {
				agent = "claude",
				name = "review",
				args = "--model opus",
				prompt = "read the diff",
				cwd = "/srv/api",
				how = "tab",
			},
		},
	}, nil)
	launch.run(cx, config, {
		agent = cfg.find_agent(config, "claude") :: cfg.Agent,
		preset = cfg.find_preset(config, "claude", "review") :: cfg.Preset,
	})
	eq(cx.started[1].opts.prompt, "read the diff")
	eq(cx.started[1].opts.cwd, "/srv/api")
	eq(cx.started[1].opts.how, "tab")
	stub.reset()
end)

test("restart repeats a launch, and kill ends one", function()
	stub.reset()
	local cx = stub.window_cx("/work/app")
	local config = cfg.defaults()
	local first = launch.run(cx, config, {
		agent = cfg.find_agent(config, "claude") :: cfg.Agent,
		preset = cfg.find_preset(config, "claude", "yolo") :: cfg.Preset,
		prompt = "one",
	})
	local again = launch.restart(cx, config, first.record, true)
	eq(cx.stopped[1], first.pane, "the old agent block was stopped")
	eq(#cx.started, 2)
	eq(cx.started[2].opts.prompt, "one")
	eq(runs.get(first.pane), nil)
	truthy(runs.get(again.pane))
	launch.kill(cx, again.pane)
	eq(cx.stopped[2], again.pane)
	eq(runs.get(again.pane), nil)
	raises(function()
		launch.restart(cx, cfg.defaults(), {
			pane = 1,
			agent = "gone",
			preset = "gone:gone",
			label = "x",
			cwd = "/",
			command = "x",
			started_at = os.time(),
		}, false)
	end, "no longer configured")
	stub.reset()
end)

test("a follow-up prompt is typed into the pane, not asked", function()
	stub.reset()
	local cx = stub.window_cx("/work/app")
	truthy(launch.send(cx, 10, "what next"))
	eq(cx.typed[1].pane, 10)
	eq(cx.typed[1].text, "what next\r")
	truthy(not launch.send(cx, 10, "   "), "a blank prompt is not sent")
	raises(function()
		cx.agents:ask(10, "x")
	end, "pending prompt")
	stub.reset()
end)

-- links --------------------------------------------------------------------

test("links carry an action and its parameters", function()
	eq(url.build("focus", { pane = "12" }), "tern-agents://focus?pane=12")
	local action, params = url.parse("tern-agents://launch?preset=claude%3Ayolo")
	eq(action, "launch")
	eq(params.preset, "claude:yolo")
	eq(url.parse("https://example.com"), nil)
end)

test("the one-line field edits like a field", function()
	local f = field.new("abc")
	eq(f.cursor, 3)
	field.key(f, stub.key("backspace"))
	eq(f.text, "ab")
	field.key(f, stub.key("x", "x"))
	eq(f.text, "abx")
	field.key(f, stub.key("home"))
	eq(f.cursor, 0)
	truthy(not field.key(f, stub.key("f5")))
end)

-- both halves load ---------------------------------------------------------

test("the host half defines its blocks and watches for exits", function()
	stub.reset()
	require("../host")
	truthy(stub.registered.blocks.list, "the Agents block")
	truthy(stub.registered.blocks.pick)
	truthy(stub.registered.blocks.line)
	truthy(stub.registered.events.pane_exited, "exit statuses come from the host half")
	runs.put(record(21, os.time()))
	stub.registered.events.pane_exited[1]({ pane = 21, status = 1 }, stub.block_cx())
	eq((runs.get(21) :: runs.Record).exited, 1)
	stub.reset()
end)

test("the window half registers its commands, routes, status line and exports", function()
	stub.reset()
	require("../window")
	local ids: { [string]: boolean } = {}
	for _, c in stub.registered.commands do
		ids[c.id] = true
	end
	for _, id in { "new", "quick", "default", "restart", "kill", "dup", "send", "addpreset", "editpreset", "rmpreset", "setdefault", "addagent", "openjson", "refresh", "importorca", "open" } do
		truthy(ids[id], "command " .. id)
	end
	eq(#stub.registered.links, 1)
	truthy(stub.registered.status, "a status formatter")
	for _, name in { "launch", "presets", "agents", "running", "send" } do
		truthy(stub.registered.exports[name], "export " .. name)
		truthy(#stub.registered.exports[name].spec.doc <= 1024)
		truthy(#stub.registered.exports[name].spec.sig <= 1024)
	end
end)

test("the status line names the agent in a tracked pane", function()
	runs.put(record(31, os.time()))
	-- The formatter reads the records the window half holds; a focus event is
	-- how another window's (or the host half's) changes reach it.
	stub.registered.events.focus[1]({ pane = 31, tab = 1 }, stub.window_cx())
	local segments = stub.registered.status({
		pane = 31,
		title = "◐ thinking",
		busy = true,
		program = "zsh",
		cwd = "/r",
	})
	truthy(segments, "a segment for a tracked pane")
	has(segments[1].text, "Claude Code · yolo")
	has(segments[1].text, "working")
	eq(segments[1].command, "plugin.agents.open")
	eq(stub.registered.status({ pane = 999, title = "", busy = false, program = "zsh", cwd = "/r" }), nil)
	stub.reset()
end)

test("records of panes that are gone are swept on a focus change", function()
	stub.reset()
	runs.put(record(32, os.time() - 60))
	runs.put(record(33, os.time()))
	-- The window's panes are 10 only, so 32 (old) goes and 33 (young, maybe
	-- not listed yet) stays.
	stub.registered.events.focus[1]({ pane = 10, tab = 1 }, stub.window_cx())
	eq(runs.get(32), nil, "a pane closed from outside this window")
	truthy(runs.get(33), "a launch Tern may not have listed yet")
	stub.reset()
end)

test("a palette command opens its dialog, and the link launches", function()
	stub.reset()
	local cx = stub.window_cx("/work/app")
	-- A probe has to have happened for anything to be offered.
	detect.refresh({ { id = "claude", bin = "claude" } }, nil)
	stub.answer(cx, 0, "claude\t/usr/local/bin/claude\n")
	local run = nil
	for _, c in stub.registered.commands do
		if c.id == "new" then
			run = c.run
		end
	end
	truthy(run, "New agent…")
	run(cx)
	local arg, kind = stub.last_block(cx)
	eq(kind, "agents.pick")
	truthy(#arg.items > 0, "presets to pick from")
	-- The block answers with a link; the window's route handles it.
	local route = stub.registered.links[1]
	local decision = route({ url = url.build("pick", { token = arg.token, choice = "1" }), pane = 99, mods = {} }, cx)
	eq(decision.handled, true)
	local prompt_arg = stub.last_block(cx)
	has(prompt_arg.title, "Prompt")
	route({ url = url.build("line", { token = prompt_arg.token, line = "Reply PONG" }), pane = 99, mods = {} }, cx)
	eq(#cx.started, 1, "the agent block was started")
	eq(cx.started[1].opts.prompt, "Reply PONG")
	stub.reset()
end)

test("a row's link focuses, prompts and kills", function()
	stub.reset()
	local cx = stub.window_cx("/work/app")
	local config = cfg.defaults()
	local result = launch.run(cx, config, {
		agent = cfg.find_agent(config, "claude") :: cfg.Agent,
		preset = cfg.find_preset(config, "claude", "yolo") :: cfg.Preset,
		prompt = "one",
	})
	local route = stub.registered.links[1]
	route({ url = url.build("focus", { pane = tostring(result.pane) }), pane = 5, mods = {} }, cx)
	eq(cx.focused[1], result.pane)
	route({ url = url.build("send", { pane = tostring(result.pane) }), pane = 5, mods = {} }, cx)
	local arg = stub.last_block(cx)
	has(arg.title, "Prompt · Claude Code · yolo")
	route({ url = url.build("kill", { pane = tostring(result.pane) }), pane = 5, mods = {} }, cx)
	eq(cx.stopped[1], result.pane)
	route({ url = url.build("kill", { pane = "4242" }), pane = 5, mods = {} }, cx)
	has(cx.toasts[#cx.toasts].sub, "no longer tracked")
	eq(route({ url = "https://example.com", pane = 5, mods = {} }, cx), nil, "other links are not ours")
	stub.reset()
end)

test("quick entry from the palette launches what it parsed", function()
	stub.reset()
	local cx = stub.window_cx("/work/app")
	local run = nil
	for _, c in stub.registered.commands do
		if c.id == "quick" then
			run = c.run
		end
	end
	run(cx)
	local arg = stub.last_block(cx)
	eq(arg.grammar, "quick")
	local route = stub.registered.links[1]
	route({ url = url.build("line", { token = arg.token, line = "claude yolo fix the build @/srv/api" }), pane = 9, mods = {} }, cx)
	eq(#cx.started, 1)
	eq(cx.started[1].opts.prompt, "fix the build")
	eq(cx.started[1].opts.cwd, "/srv/api")
	has(cx.started[1].opts.command, "--dangerously-skip-permissions")
	stub.reset()
end)

-- blocks -------------------------------------------------------------------

test("the Agents block lists the launches and offers presets", function()
	stub.reset()
	local now = os.time()
	runs.put(record(41, now - 30))
	-- Pane 7 is the block's own; its tick stops when it is no longer listed.
	stub.panes = {
		{ pane = 7, title = "Agents", cwd = "/r", program = "agents" },
		{ pane = 41, title = "◐ thinking", cwd = "/r", program = "zsh" },
	}
	stub.kv.detected = { found = { claude = "/usr/local/bin/claude" }, at = now, shell = "/bin/zsh" }
	local def = stub.registered.blocks.list
	local cx = stub.block_cx()
	local state = def.init(cx, {}, nil)
	eq(#state.rows, 1)
	eq(state.rows[1].status.state, "working")
	has(def.title(state), "Agents 1")
	local view = def.view(state, cx)
	truthy(view.main)
	truthy(view.dock)
	truthy(#state.presets > 0, "a preset to launch")
	-- Clicking a row's Focus chip opens our link.
	def.event(state, { ev = "action", act = "focus", value = "41" }, cx)
	eq(cx.opened[1], "tern-agents://focus?pane=41")
	def.key(state, stub.key("n"), cx)
	eq(cx.opened[2], "tern-agents://new")
	eq(def.key(state, stub.key("z"), cx), false)
	-- Its tick re-reads titles and re-renders.
	truthy(#stub.timers > 0)
	stub.timers[#stub.timers].fn()
	truthy(cx.renders > 0)
	-- With its own pane gone, the tick stops rather than drawing into nothing.
	local renders = cx.renders
	stub.panes = {}
	stub.timers[#stub.timers].fn()
	eq(cx.renders, renders)
	stub.reset()
end)

test("the picker and the line dialog answer with a link", function()
	stub.reset()
	local picker = stub.registered.blocks.pick
	local cx = stub.block_cx()
	local arg = tern.json.encode({
		token = "tok",
		title = "New agent",
		items = { { label = "Claude Code · yolo", detail = "claude --dangerously-skip-permissions", choice = "1" } },
	})
	local state = picker.init(cx, { arg }, nil)
	truthy(picker.view(state, cx).main)
	picker.key(state, stub.key("enter"), cx)
	eq(cx.opened[1], "tern-agents://pick?choice=1&token=tok")
	raises(function()
		picker.init(cx, {}, nil)
	end, "needs the window's launch argument")

	local dialog = stub.registered.blocks.line
	local cx2 = stub.block_cx()
	local arg2 = tern.json.encode({
		token = "tok2",
		title = "Quick agent",
		grammar = "quick",
		home = "/Users/me",
		agents = { { id = "claude", label = "Claude Code", bin = "claude", presets = { "claude", "yolo" } } },
	})
	local state2 = dialog.init(cx2, { arg2 }, nil)
	for _, key in { "c", "l", "a", "u", "d", "e" } do
		dialog.key(state2, stub.key(key, key), cx2)
	end
	eq(state2.line.text, "claude")
	truthy(dialog.view(state2, cx2).main, "it previews what the line resolves to")
	dialog.key(state2, stub.key("enter"), cx2)
	eq(cx2.opened[1], "tern-agents://line?line=claude&token=tok2")
	eq(dialog.save(state2).line, "claude")
	stub.reset()
end)

-- Carly exports ------------------------------------------------------------

-- Carly pads an export's omitted fixed arguments with nil, so the context and
-- the call handle always arrive in the same places; `arity` says how many the
-- export declares before them.
local function call_export(name: string, arity: number, cx: any, ...): any
	local export = stub.registered.exports[name]
	local fake_call = { cancelled = false }
	function fake_call:reply(_v)
		return true
	end
	function fake_call:fail(_m)
		return true
	end
	function fake_call:wait(_ms)
		return nil
	end
	local args: { any } = table.pack(...) :: any
	local padded: { any } = {}
	for i = 1, arity do
		padded[i] = args[i]
	end
	padded[arity + 1] = cx
	padded[arity + 2] = fake_call
	return export.fn(table.unpack(padded, 1, arity + 2))
end

test("Carly can launch, list and send", function()
	stub.reset()
	local cx = stub.window_cx("/work/app")
	stub.kv.detected = { found = { claude = "/usr/local/bin/claude" }, at = os.time(), shell = "/bin/zsh" }
	local launched = call_export("launch", 4, cx, { agent = "claude", preset = "yolo", prompt = "Reply PONG" })
	eq(launched.agent, "claude")
	eq(launched.preset, "claude:yolo")
	eq(launched.kind, "block")
	has(launched.command, "--dangerously-skip-permissions")
	eq(cx.started[1].opts.prompt, "Reply PONG")

	local running = call_export("running", 0, cx)
	eq(#running, 1)
	eq(running[1].pane, launched.pane)
	eq(running[1].state, "running", "no title yet, so only \"alive\"")

	local presets = call_export("presets", 0, cx)
	truthy(#presets > 0)
	local agents = call_export("agents", 0, cx)
	local claude = nil
	for _, row in agents do
		if row.id == "claude" then
			claude = row
		end
	end
	truthy(claude)
	eq(claude.detected, true)
	eq(claude.path, "/usr/local/bin/claude")
	eq(claude.prompt_arg, "positional")

	local sent = call_export("send", 2, cx, launched.pane, "and now?")
	eq(sent.sent, "and now?")
	raises(function()
		call_export("send", 2, cx, "nope", "x")
	end, "must be a number")
	raises(function()
		call_export("launch", 4, cx, { agent = "claude", nope = 1 })
	end, "unknown launch option")
	raises(function()
		call_export("launch", 4, cx, { agent = "nope" })
	end, "No agent")
	stub.reset()
end)

-- result -------------------------------------------------------------------

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
	error(string.format("%d test(s) failed", failed), 0)
end
