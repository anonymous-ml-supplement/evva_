# Live runtime provenance

- Agent framework: AgentLab with BrowserGym
- Benchmark: WebArena-Verified
- Primary live backbone: `openai/gpt-5-mini-2025-08-07`
- Agent image: `evva-w12-source-aligned-agentlab:0.4.2-bg0.14.3-runtime-compatible`
- Reddit service image: `am1n3e/webarena-verified-reddit:latest`
- Execution design: 30 frozen candidates x 2 arms x 3 repetitions = 180 branches
- Candidate rule: first tool-mediated action after a fresh reset

The released runtime source uses AgentLab's `AGENT_GPT5_MINI` configuration, with the frozen configuration override binding it to `openai/gpt-5-mini-2025-08-07`. Private credentials are not included. Copy `env.docker.template` to `env.docker` outside version control and provide valid credentials before a full execution rerun.
