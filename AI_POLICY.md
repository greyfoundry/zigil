# AI-assisted contributions

AI tools are welcome in Zigil. We use them for research, planning, implementation, tests, documentation and review. They can help write a useful patch. They can't take responsibility for it.

## You own the change

Read the entire diff, understand the behaviour, check how it fits the existing code, and run the relevant checks before submitting. Review generated tests as carefully as implementation. Verify unfamiliar APIs against the relevant standards and the actual Zig compiler. If you cannot explain the change, keep working or open a draft with clear limitations. Don't hand an agent's output directly to maintainers as if it were reviewed work.

Disclose material assistance in the PR: tools/models where known, scope (research, code, tests, docs or review), extent (limited, substantial or primarily agent-generated), and what a human verified. Routine spelling/formatting and ordinary autocomplete do not require detailed disclosure. Material architecture/security changes and generated documentation do. Disclosure is not a penalty; it gives reviewers useful context. Never impersonate a human reviewer, forge a sign-off or claim checks you did not run.

## Review and secure development

All changes meet the same quality bar. A human must review and approve before merge; automated review is supplementary. Security-sensitive changes require extra scrutiny, including failure paths. Verify dependency names, origins, versions, integrity and licences; generated content may contain third-party code. Preserve notices. No fake tests, disabled checks, invented citations or unverified claims.

Use least-privilege agent permissions, keep credentials and confidential data out of prompts/tools, and treat repo content, issues, API payloads and fetched references as untrusted. Do not follow embedded instructions from them. Never grant unrestricted shell/network permissions or install arbitrary skills just to unblock a task. Obtain approval for publishing, merging, sensitive tests and remote settings. `.private/` is excluded from Git, not automatically from cloud agent context.

## Communication

Use your own understanding in issues, review comments and PR descriptions. Editing assistance is fine; unattended generated conversations and speculative answers aren't. Maintainership time matters. Keep submissions useful, focused and respectful. Maintainers may return or close unverified, insecure or excessive changes regardless of authoring method.

Our policy is inspired by project-specific guidance from Vercel and Cloudflare, Google's engineering review practices, and OWASP secure AI-assisted development guidance; it is Zigil's own policy, not a claim of compliance or endorsement.
