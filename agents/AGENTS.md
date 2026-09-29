# Instructions

I build web apps (React, Tailwind) and React Native apps (Expo), all in TypeScript.
I work from jupiter-mbp and run agents on saturn-mbp and neptune-mbp through T3 Code.
Threads move between machines, so behave the same on all of them.

## Working with me

- Questions are read-only. When I ask something, answer it; don't edit files.
- Make routine choices yourself. Ask when a decision matters and has several reasonable options, or when you'd delete or restructure existing work.
- If you don't know a flag, env var or API, check `--help`, the installed typings or the docs. Never guess.
- Tell me when I'm wrong or a task is too big for one go.
- Write short, plain English. No em dashes.
- When I correct a habit that applies everywhere, suggest a one-line addition to `~/Code/fleet/agents/AGENTS.md`.

## Code

- Keep solutions simple (YAGNI). If there's a simpler way, propose it.
- Touch only what the task needs. Mention unrelated problems instead of fixing them.
- Fix the root cause, not the symptom.
- Never use `any` unless there's no typed alternative.
- Never use deprecated APIs. Check the installed typings for the replacement.
- Comments explain why, briefly. No history or ticket refs.
- Use the package manager the lockfile indicates. For new projects use bun. In Expo projects, add packages with `npx expo install`.

## Machines

- Each machine runs several agents and dev servers. Pick a free port. Never kill a process by name or pattern, only one you started.
- Changes you didn't make belong to me or another agent. Leave them alone.
- Give URLs with the machine's MagicDNS name, not localhost.

## Checks and git

- Don't run builds or repo-wide checks unless asked. Run typecheck, lint and tests for what you changed.
- Before saying it's done, show the command you ran and its result. Say what you couldn't verify.
- Never commit, push or open a PR unless asked. Never `reset --hard`, `clean`, force-push or amend unless asked.
- Keep commit messages short. Don't commit plans or scratch files.
- Never print, log or commit secrets: `.env` files, tokens, T3 pairing links.

New projects: Bun, React, Tailwind, Vercel or Netlify. Mobile: Expo, Unistyles, MMKV, Reanimated. Shared: Convex, Clerk, Zod, React Hook Form.
