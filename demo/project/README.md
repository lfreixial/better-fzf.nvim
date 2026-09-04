# greetdemo

A tiny multi-language demo project used to try out
[better-fzf.nvim](https://github.com/lfreixial/better-fzf.nvim).

- `cmd/server` — Go HTTP server that says `hello`
- `internal/greeter` — greeting library (plus its test)
- `pkg/api` — API handler plumbing
- `scripts/seed.py` — Python seed script
- `web/app.ts` — TypeScript client

Search for `hello`, `TODO`, or `handler` across it, e.g.

```
:BFzf "hello" go
:BFzf TODO
:BFzfFile go,ts
```

Everything here is throwaway — delete the whole `demo/project` directory
whenever you like.
